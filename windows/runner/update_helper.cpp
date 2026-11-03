#include <windows.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <tlhelp32.h>
#include <winver.h>

#include <algorithm>
#include <array>
#include <cwchar>
#include <cwctype>
#include <filesystem>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kInstallerPrefix[] = L"SuelosAR-Setup-";
constexpr wchar_t kUpdateDirectoryPrefix[] = L"suelosar-update-";
constexpr wchar_t kHelperDirectoryPrefix[] = L"suelosar-update-helper-";
constexpr wchar_t kHelperName[] = L"suelosar_update_helper.exe";
constexpr wchar_t kAppName[] = L"suelosar.exe";
constexpr wchar_t kUninstallKey[] =
    L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{C7098677-ADDE-4FE4-A0FA-E24AC63B3CD0}_is1";

std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), towlower);
  return value;
}

std::wstring FullPath(const std::wstring& value) {
  std::error_code error;
  const auto path = std::filesystem::weakly_canonical(value, error);
  return error ? std::wstring() : path.wstring();
}

std::wstring ParentPath(const std::wstring& value) {
  return std::filesystem::path(value).parent_path().wstring();
}

bool IsDirectChild(const std::wstring& parent, const std::wstring& child) {
  return Lower(ParentPath(child)) == Lower(FullPath(parent));
}

bool IsNamedDirectory(const std::wstring& path, const wchar_t* prefix) {
  const auto name = std::filesystem::path(path).filename().wstring();
  return Lower(name).rfind(Lower(prefix), 0) == 0;
}

bool IsWithin(const std::wstring& parent, const std::wstring& child) {
  auto normalized_parent = Lower(FullPath(parent));
  auto normalized_child = Lower(FullPath(child));
  if (normalized_parent.empty() || normalized_child.empty()) return false;
  if (normalized_parent.back() != L'\\') normalized_parent.push_back(L'\\');
  return normalized_child.rfind(normalized_parent, 0) == 0;
}

bool IsStableVersion(const std::wstring& value);

std::wstring PersistentUpdateRoot() {
  const DWORD required = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
  if (required <= 1) return {};
  std::vector<wchar_t> local_app_data(required);
  const DWORD length = GetEnvironmentVariableW(
      L"LOCALAPPDATA", local_app_data.data(), required);
  if (length == 0 || length >= required) return {};
  const auto path = std::filesystem::path(
      std::wstring(local_app_data.data(), length));
  return FullPath((path / L"SuelosAR" / L"Updates").wstring());
}

std::wstring GenerateConfirmationToken() {
  std::array<UCHAR, 16> bytes{};
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    return {};
  }
  static constexpr wchar_t digits[] = L"0123456789abcdef";
  std::wstring token;
  token.reserve(bytes.size() * 2);
  for (const auto byte : bytes) {
    token.push_back(digits[byte >> 4]);
    token.push_back(digits[byte & 0x0F]);
  }
  return token;
}

bool IsConfirmationToken(const std::wstring& token) {
  return token.size() == 32 &&
         std::all_of(token.begin(), token.end(), [](wchar_t c) {
           return (c >= L'0' && c <= L'9') ||
                  (c >= L'a' && c <= L'f');
         });
}

bool WriteSuccessConfirmation(const std::wstring& token,
                              const std::wstring& version) {
  if (!IsConfirmationToken(token) || !IsStableVersion(version)) return false;
  const auto update_root = PersistentUpdateRoot();
  if (update_root.empty()) return false;
  const auto confirmation_directory =
      std::filesystem::path(update_root).parent_path() /
      L"UpdateConfirmations";
  std::error_code error;
  std::filesystem::create_directories(confirmation_directory, error);
  if (error) return false;

  const auto marker = confirmation_directory / (token + L".txt");
  const auto temporary = confirmation_directory / (token + L".tmp");
  std::string ascii_version;
  ascii_version.reserve(version.size());
  for (const wchar_t character : version) {
    if (character > 0x7F) return false;
    ascii_version.push_back(static_cast<char>(character));
  }
  const std::string content = "version=" + ascii_version + "\r\n";
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool write_succeeded =
      WriteFile(file, content.data(), static_cast<DWORD>(content.size()),
                &written, nullptr) != 0 &&
      written == static_cast<DWORD>(content.size()) &&
      FlushFileBuffers(file) != 0;
  CloseHandle(file);
  if (!write_succeeded ||
      !MoveFileExW(temporary.c_str(), marker.c_str(), MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

bool IsAllowedUpdateDirectory(const std::wstring& update_directory,
                              const std::wstring& temp_path) {
  if (IsWithin(temp_path, update_directory)) return true;
  const auto persistent_root = PersistentUpdateRoot();
  return !persistent_root.empty() &&
         IsDirectChild(persistent_root, update_directory);
}

void WriteStatus(const char* status) {
  const HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output == nullptr || output == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  const std::string line = std::string(status) + "\r\n";
  WriteFile(output, line.data(), static_cast<DWORD>(line.size()), &written,
            nullptr);
  FlushFileBuffers(output);
}

void ShowFailure(const std::wstring& message) {
  MessageBoxW(nullptr, message.c_str(), L"Actualización de SuelosAR",
              MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
}

bool IsSha256(const std::wstring& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](wchar_t c) {
           return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') ||
                  (c >= L'A' && c <= L'F');
         });
}

bool IsStableVersion(const std::wstring& value) {
  size_t start = 0;
  for (size_t index = 0; index < 3; ++index) {
    const size_t end = index == 2 ? value.size() : value.find(L'.', start);
    if (end == std::wstring::npos || end == start) return false;
    const auto token = value.substr(start, end - start);
    if ((token.size() > 1 && token.front() == L'0') || token.size() > 5) {
      return false;
    }
    if (!std::all_of(token.begin(), token.end(), [](wchar_t c) {
          return c >= L'0' && c <= L'9';
        })) {
      return false;
    }
    try {
      if (std::stoul(token) > 65535) return false;
    } catch (...) {
      return false;
    }
    if (index < 2) start = end + 1;
  }
  return true;
}

std::wstring Sha256File(const std::wstring& path) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_length = 0;
  DWORD bytes_read = 0;
  DWORD hash_length = 0;
  std::vector<UCHAR> hash_object;
  std::vector<UCHAR> digest;
  std::vector<UCHAR> buffer(1024 * 1024);
  HANDLE file = INVALID_HANDLE_VALUE;
  std::wstring result;

  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                  0) != 0) {
    return result;
  }
  if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_length),
                        sizeof(object_length), &bytes_read, 0) != 0 ||
      BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
                        reinterpret_cast<PUCHAR>(&hash_length),
                        sizeof(hash_length), &bytes_read, 0) != 0) {
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return result;
  }
  hash_object.resize(object_length);
  digest.resize(hash_length);
  if (BCryptCreateHash(algorithm, &hash, hash_object.data(), object_length,
                       nullptr, 0, 0) != 0) {
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return result;
  }
  file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                     OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    BCryptDestroyHash(hash);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return result;
  }
  bool succeeded = true;
  while (true) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count,
                  nullptr)) {
      succeeded = false;
      break;
    }
    if (count == 0) break;
    if (BCryptHashData(hash, buffer.data(), count, 0) != 0) {
      succeeded = false;
      break;
    }
  }
  if (succeeded && BCryptFinishHash(hash, digest.data(), hash_length, 0) == 0) {
    static constexpr wchar_t digits[] = L"0123456789abcdef";
    result.reserve(hash_length * 2);
    for (const UCHAR byte : digest) {
      result.push_back(digits[byte >> 4]);
      result.push_back(digits[byte & 0x0F]);
    }
  }
  CloseHandle(file);
  BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  return result;
}

bool VersionMatches(const std::wstring& executable,
                    const std::wstring& expected) {
  unsigned int major = 0;
  unsigned int minor = 0;
  unsigned int patch = 0;
  if (!IsStableVersion(expected) ||
      swscanf_s(expected.c_str(), L"%u.%u.%u", &major, &minor, &patch) != 3) {
    return false;
  }
  DWORD ignored = 0;
  const DWORD size = GetFileVersionInfoSizeW(executable.c_str(), &ignored);
  if (size == 0) return false;
  std::vector<BYTE> info(size);
  if (!GetFileVersionInfoW(executable.c_str(), 0, size, info.data())) {
    return false;
  }
  VS_FIXEDFILEINFO* version_info = nullptr;
  UINT length = 0;
  if (!VerQueryValueW(info.data(), L"\\",
                      reinterpret_cast<void**>(&version_info), &length) ||
      version_info == nullptr || length < sizeof(VS_FIXEDFILEINFO)) {
    return false;
  }
  return HIWORD(version_info->dwProductVersionMS) == major &&
         LOWORD(version_info->dwProductVersionMS) == minor &&
         HIWORD(version_info->dwProductVersionLS) == patch;
}

std::wstring ReadInstallLocation(HKEY hive) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(hive, kUninstallKey, 0,
                    KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key) !=
      ERROR_SUCCESS) {
    return {};
  }

  DWORD type = 0;
  DWORD byte_count = 0;
  if (RegQueryValueExW(key, L"InstallLocation", nullptr, &type, nullptr,
                       &byte_count) != ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ) ||
      byte_count < sizeof(wchar_t)) {
    RegCloseKey(key);
    return {};
  }

  std::vector<wchar_t> value(byte_count / sizeof(wchar_t) + 1, L'\0');
  if (RegQueryValueExW(key, L"InstallLocation", nullptr, &type,
                       reinterpret_cast<LPBYTE>(value.data()),
                       &byte_count) != ERROR_SUCCESS) {
    RegCloseKey(key);
    return {};
  }
  RegCloseKey(key);

  std::wstring directory(value.data());
  if (type == REG_EXPAND_SZ) {
    const DWORD required =
        ExpandEnvironmentStringsW(directory.c_str(), nullptr, 0);
    if (required == 0) return {};
    std::vector<wchar_t> expanded(required);
    if (ExpandEnvironmentStringsW(directory.c_str(), expanded.data(),
                                  required) == 0) {
      return {};
    }
    directory.assign(expanded.data());
  }

  const auto install_directory = FullPath(directory);
  if (install_directory.empty()) return {};
  const auto executable =
      FullPath((std::filesystem::path(install_directory) / kAppName).wstring());
  if (executable.empty()) return {};
  const DWORD attributes = GetFileAttributesW(executable.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    return {};
  }
  return executable;
}

std::wstring ResolveInstalledAppPath() {
  auto path = ReadInstallLocation(HKEY_LOCAL_MACHINE);
  if (path.empty()) path = ReadInstallLocation(HKEY_CURRENT_USER);
  return path;
}

bool HasAnotherAppProcess(const std::wstring& app_path, DWORD parent_pid) {
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return true;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  bool found = false;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == GetCurrentProcessId() ||
          entry.th32ProcessID == parent_pid) {
        continue;
      }
      if (Lower(entry.szExeFile) != kAppName) continue;
      const HANDLE process =
          OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                      entry.th32ProcessID);
      if (process == nullptr) {
        found = true;
        break;
      }
      std::vector<wchar_t> buffer(32768);
      DWORD length = static_cast<DWORD>(buffer.size());
      if (QueryFullProcessImageNameW(process, 0, buffer.data(), &length) &&
          Lower(FullPath(std::wstring(buffer.data(), length))) ==
              Lower(FullPath(app_path))) {
        found = true;
        CloseHandle(process);
        break;
      }
      CloseHandle(process);
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return found;
}

std::wstring QuoteArgument(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t backslashes = 0;
  for (const wchar_t c : value) {
    if (c == L'\\') {
      ++backslashes;
    } else if (c == L'\"') {
      result.append(backslashes * 2 + 1, L'\\');
      result.push_back(c);
      backslashes = 0;
    } else {
      result.append(backslashes, L'\\');
      backslashes = 0;
      result.push_back(c);
    }
  }
  result.append(backslashes * 2, L'\\');
  result.push_back(L'\"');
  return result;
}

bool LaunchApplication(const std::wstring& app_path,
                       const std::wstring& helper_dir,
                       const std::wstring& outcome,
                       const std::wstring& version,
                       const std::wstring& confirmation_token,
                       HANDLE* process_out) {
  std::wstring command = QuoteArgument(app_path);
  command += L" --suelosar-update-helper-cleanup=" + QuoteArgument(helper_dir);
  command += L" --suelosar-update-helper-pid=" +
             std::to_wstring(GetCurrentProcessId());
  command += L" --suelosar-update-result=" + outcome;
  command += L" --suelosar-update-version=" + version;
  if (!confirmation_token.empty()) {
    command += L" --suelosar-update-confirmation=" + confirmation_token;
  }
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(app_path.c_str(), mutable_command.data(), nullptr, nullptr,
                      FALSE, 0, nullptr, ParentPath(app_path).c_str(), &startup,
                      &process)) {
    return false;
  }
  CloseHandle(process.hThread);
  *process_out = process.hProcess;
  return true;
}

bool DeleteUpdateDirectory(const std::wstring& temp_directory) {
  std::error_code error;
  const auto attributes = GetFileAttributesW(temp_directory.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }
  std::filesystem::remove_all(temp_directory, error);
  return !error && !std::filesystem::exists(temp_directory, error);
}

int Run(const std::vector<std::wstring>& args) {
  if (args.size() != 8) {
    WriteStatus("ERROR_ARGUMENTS");
    return 2;
  }
  const std::wstring installer_path = FullPath(args[1]);
  const std::wstring expected_hash = Lower(args[2]);
  const std::wstring expected_version = args[3];
  const std::wstring app_path = FullPath(args[4]);
  const std::wstring update_directory = FullPath(args[5]);
  const std::wstring helper_directory = FullPath(args[7]);
  DWORD parent_pid = 0;
  try {
    parent_pid = static_cast<DWORD>(std::stoul(args[6]));
  } catch (...) {
    WriteStatus("ERROR_PARENT_PID");
    return 2;
  }

  if (installer_path.empty() || app_path.empty() || update_directory.empty() ||
      helper_directory.empty() || parent_pid == 0 ||
      !IsSha256(expected_hash) || !IsStableVersion(expected_version) ||
      Lower(std::filesystem::path(app_path).filename().wstring()) != kAppName ||
      Lower(std::filesystem::path(installer_path).filename().wstring()) !=
          Lower(std::wstring(kInstallerPrefix) + expected_version + L".exe") ||
      !IsDirectChild(update_directory, installer_path) ||
      !IsNamedDirectory(update_directory, kUpdateDirectoryPrefix) ||
      !IsNamedDirectory(helper_directory, kHelperDirectoryPrefix)) {
    WriteStatus("ERROR_ARGUMENT_VALIDATION");
    return 2;
  }

  wchar_t temp_path[MAX_PATH]{};
  const DWORD temp_length = GetTempPathW(MAX_PATH, temp_path);
  if (temp_length == 0 || temp_length >= MAX_PATH ||
      !IsAllowedUpdateDirectory(update_directory, temp_path) ||
      !IsWithin(temp_path, helper_directory) ||
      !IsDirectChild(helper_directory,
                     FullPath(helper_directory + L"\\" + kHelperName))) {
    WriteStatus("ERROR_UPDATE_PATH");
    return 2;
  }
  const HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, parent_pid);
  if (parent == nullptr) {
    WriteStatus("ERROR_PARENT_PROCESS");
    return 2;
  }
  if (HasAnotherAppProcess(app_path, parent_pid)) {
    CloseHandle(parent);
    WriteStatus("ERROR_ANOTHER_INSTANCE");
    return 2;
  }
  if (Sha256File(installer_path) != expected_hash) {
    CloseHandle(parent);
    WriteStatus("ERROR_HASH_MISMATCH");
    return 2;
  }

  WriteStatus("READY");
  CloseHandle(GetStdHandle(STD_OUTPUT_HANDLE));
  const DWORD parent_wait = WaitForSingleObject(parent, 30000);
  if (parent_wait != WAIT_OBJECT_0) {
    CloseHandle(parent);
    ShowFailure(L"SuelosAR no se cerró. El instalador no se inició.");
    return 1;
  }
  CloseHandle(parent);

  const std::wstring log_path = update_directory + L"\\setup.log";
  const std::wstring restart_marker_path =
      update_directory + L"\\vcruntime-restart-required.flag";
  DeleteFileW(restart_marker_path.c_str());
  const std::wstring parameters =
      L"/LOG=" + QuoteArgument(log_path) +
      L" /NORESTART /NORESTARTAPPLICATIONS";
  SHELLEXECUTEINFOW launch{};
  launch.cbSize = sizeof(launch);
  launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  launch.lpVerb = L"runas";
  launch.lpFile = installer_path.c_str();
  launch.lpParameters = parameters.c_str();
  launch.lpDirectory = update_directory.c_str();
  launch.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&launch) || launch.hProcess == nullptr) {
    const DWORD error = GetLastError();
    ShowFailure(error == ERROR_CANCELLED
                    ? L"Se canceló la confirmación de Windows. No se instaló la actualización."
                    : L"No se pudo iniciar el instalador con los permisos necesarios.");
    HANDLE recovered_process = nullptr;
    if (LaunchApplication(app_path, helper_directory, L"cancelled",
                          expected_version, L"", &recovered_process)) {
      CloseHandle(recovered_process);
    }
    return 2;
  }

  WaitForSingleObject(launch.hProcess, INFINITE);
  DWORD exit_code = 0;
  const bool got_exit_code = GetExitCodeProcess(launch.hProcess, &exit_code) != 0;
  CloseHandle(launch.hProcess);
  if (!got_exit_code) exit_code = 0xFFFFFFFF;

  if (GetFileAttributesW(restart_marker_path.c_str()) !=
      INVALID_FILE_ATTRIBUTES) {
    ShowFailure(L"Visual C++ Runtime requiere reiniciar Windows. "
                L"SuelosAR no se inició; reiniciá Windows y abrí la app.");
    return 3010;
  }

  const bool setup_succeeded = exit_code == 0;
  const std::wstring installed_app_path =
      setup_succeeded ? ResolveInstalledAppPath() : std::wstring();
  const bool version_matches = !installed_app_path.empty() &&
                               VersionMatches(installed_app_path,
                                              expected_version);
  if (setup_succeeded && !version_matches) {
    ShowFailure(L"El instalador terminó, pero no se pudo verificar la versión "
                L"instalada. Se conservaron los archivos para recuperación.");
  } else if (!setup_succeeded) {
    const std::wstring message =
        exit_code == 2 || exit_code == 5
            ? L"La instalación se canceló. No se informará una actualización "
              L"completada; se conservaron los archivos descargados."
            : L"La instalación no terminó correctamente (código " +
                  std::to_wstring(exit_code) +
                  L"). Se conservaron los archivos para recuperación.";
    ShowFailure(message);
  }

  HANDLE restarted_process = nullptr;
  const std::wstring outcome = version_matches
                                   ? L"installed"
                                   : (exit_code == 2 || exit_code == 5
                                          ? L"cancelled"
                                          : L"recovered");
  const std::wstring& app_to_launch =
      version_matches ? installed_app_path : app_path;
  const std::wstring confirmation_token =
      version_matches ? GenerateConfirmationToken() : std::wstring();
  if (!LaunchApplication(app_to_launch, helper_directory, outcome,
                         expected_version, confirmation_token,
                         &restarted_process)) {
    ShowFailure(L"No se pudo volver a iniciar SuelosAR. Podés iniciarlo desde "
                L"el acceso directo; los archivos del instalador se conservaron.");
    return 1;
  }
  const DWORD idle_result = WaitForInputIdle(restarted_process, 15000);
  DWORD restarted_exit = STILL_ACTIVE;
  const bool got_restarted_exit =
      GetExitCodeProcess(restarted_process, &restarted_exit) != 0;
  CloseHandle(restarted_process);
  if (idle_result != 0 || !got_restarted_exit ||
      restarted_exit != STILL_ACTIVE) {
    ShowFailure(L"SuelosAR se instaló, pero no se pudo confirmar su inicio. "
                L"Se conservaron los archivos descargados para recuperación.");
    return 1;
  }
  if (!version_matches) return 1;
  if (confirmation_token.empty() ||
      !WriteSuccessConfirmation(confirmation_token, expected_version)) {
    ShowFailure(L"SuelosAR se instaló y reinició, pero no se pudo guardar "
                L"la confirmación. No se mostrará un aviso de éxito falso.");
    return 1;
  }
  // The restarted app polls for this marker. Write it before deleting the
  // potentially large installer so cleanup cannot race the app's timeout.
  if (!DeleteUpdateDirectory(update_directory)) {
    ShowFailure(L"SuelosAR se actualizó correctamente, pero no se pudo borrar "
                L"la carpeta temporal del instalador.");
    return 1;
  }
  return 0;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  int count = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &count);
  if (argv == nullptr) {
    WriteStatus("ERROR_COMMAND_LINE");
    return 2;
  }
  std::vector<std::wstring> args;
  args.reserve(static_cast<size_t>(count));
  for (int index = 0; index < count; ++index) args.emplace_back(argv[index]);
  LocalFree(argv);
  return Run(args);
}
