#include <windows.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <sddl.h>
#include <tlhelp32.h>
#include <winver.h>

#include <algorithm>
#include <array>
#include <cwchar>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <system_error>
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

struct StableVersion {
  unsigned int major = 0;
  unsigned int minor = 0;
  unsigned int patch = 0;
  bool has_build = false;
  unsigned int build = 0;
};

bool ParseVersionComponent(const std::wstring& token,
                           unsigned int* component) {
  if (token.empty() || token.size() > 5 ||
      (token.size() > 1 && token.front() == L'0') ||
      !std::all_of(token.begin(), token.end(), [](wchar_t c) {
        return c >= L'0' && c <= L'9';
      })) {
    return false;
  }
  try {
    const auto value = std::stoul(token);
    if (value > 65535) return false;
    *component = static_cast<unsigned int>(value);
    return true;
  } catch (...) {
    return false;
  }
}

bool ParseStableVersion(const std::wstring& value, StableVersion* parsed) {
  const size_t plus = value.find(L'+');
  if (plus != std::wstring::npos && value.find(L'+', plus + 1) !=
                                        std::wstring::npos) {
    return false;
  }
  const std::wstring semantic = value.substr(0, plus);
  std::array<unsigned int*, 3> components = {
      &parsed->major, &parsed->minor, &parsed->patch};
  size_t start = 0;
  for (size_t index = 0; index < components.size(); ++index) {
    const size_t end = index == components.size() - 1
                           ? semantic.size()
                           : semantic.find(L'.', start);
    if (end == std::wstring::npos || end == start ||
        !ParseVersionComponent(semantic.substr(start, end - start),
                               components[index])) {
      return false;
    }
    if (index < components.size() - 1) start = end + 1;
  }
  if (plus == std::wstring::npos) return true;
  parsed->has_build = true;
  return ParseVersionComponent(value.substr(plus + 1), &parsed->build);
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
  StableVersion parsed;
  return ParseStableVersion(value, &parsed);
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
  StableVersion expected_version;
  if (!ParseStableVersion(expected, &expected_version)) return false;
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
  const bool semantic_matches =
      HIWORD(version_info->dwProductVersionMS) == expected_version.major &&
      LOWORD(version_info->dwProductVersionMS) == expected_version.minor &&
      HIWORD(version_info->dwProductVersionLS) == expected_version.patch;
  return semantic_matches &&
         (!expected_version.has_build ||
          LOWORD(version_info->dwProductVersionLS) == expected_version.build);
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
  if (process_out == nullptr) {
    CloseHandle(process.hProcess);
  } else {
    *process_out = process.hProcess;
  }
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

struct DeltaPaths {
  std::wstring update_directory;
  std::wstring staging_directory;
  std::wstring apply_list;
  std::wstring apply_hash;
  std::wstring remove_list;
  std::wstring remove_hash;
  std::wstring target_manifest;
  std::wstring target_manifest_hash;
  std::wstring previous_manifest;
  std::wstring previous_manifest_hash;
  std::wstring target_verify_list;
  std::wstring target_verify_hash;
  std::wstring previous_verify_list;
  std::wstring previous_verify_hash;
  std::wstring local_manifest;
  std::wstring install_directory;
  std::wstring app_path;
  std::wstring baseline_version;
  std::wstring target_version;
  std::wstring installation_id;
  DWORD parent_pid = 0;
  std::wstring helper_directory;
};

struct DeltaFile {
  std::wstring path;
  unsigned long long size = 0;
  std::wstring sha256;
  std::wstring change_type;
};

bool HasValidRelativePath(const std::wstring& value) {
  if (value.empty() || value.front() == L'/' || value.front() == L'\\' ||
      value.find(L'\\') != std::wstring::npos ||
      value.find(L':') != std::wstring::npos) {
    return false;
  }
  size_t start = 0;
  while (start <= value.size()) {
    const size_t end = value.find(L'/', start);
    const auto component = value.substr(
        start, end == std::wstring::npos ? std::wstring::npos : end - start);
    if (component.empty() || component == L"." || component == L".." ||
        component.back() == L'.' || component.back() == L' ' ||
        std::any_of(component.begin(), component.end(), [](wchar_t c) {
          return c < 32 || c == L'<' || c == L'>' || c == L'"' || c == L'|' ||
                 c == L'?' || c == L'*';
        })) {
      return false;
    }
    const auto dot = component.find(L'.');
    const auto stem = Lower(component.substr(0, dot));
    if (stem == L"con" || stem == L"prn" || stem == L"aux" || stem == L"nul") {
      return false;
    }
    if (stem.size() == 4 &&
        (stem.rfind(L"com", 0) == 0 || stem.rfind(L"lpt", 0) == 0) &&
        stem[3] >= L'1' && stem[3] <= L'9') {
      return false;
    }
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  return true;
}

std::wstring Utf8ToWide(const std::string& input) {
  if (input.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         input.data(),
                                         static_cast<int>(input.size()),
                                         nullptr, 0);
  if (length <= 0) return {};
  std::wstring output(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                          static_cast<int>(input.size()), output.data(),
                          length) != length) {
    return {};
  }
  return output;
}

std::string WideToUtf8(const std::wstring& input) {
  if (input.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                         input.data(),
                                         static_cast<int>(input.size()),
                                         nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string output(static_cast<size_t>(length), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input.data(),
                          static_cast<int>(input.size()), output.data(),
                          length, nullptr, nullptr) != length) {
    return {};
  }
  return output;
}

bool ReadUtf8File(const std::wstring& path, std::wstring* output) {
  std::ifstream file(std::filesystem::path(path), std::ios::binary);
  if (!file) return false;
  const std::string bytes((std::istreambuf_iterator<char>(file)),
                          std::istreambuf_iterator<char>());
  *output = Utf8ToWide(bytes);
  return !output->empty() || bytes.empty();
}

bool WriteUtf8File(const std::wstring& path, const std::wstring& content) {
  const auto bytes = WideToUtf8(content);
  if (!content.empty() && bytes.empty()) return false;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool succeeded =
      WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written,
                nullptr) != 0 &&
      written == static_cast<DWORD>(bytes.size()) && FlushFileBuffers(file);
  CloseHandle(file);
  return succeeded;
}

bool WriteAtomicUtf8File(const std::wstring& path,
                         const std::wstring& content) {
  const std::wstring temporary = path + L".suelosar-tmp-" +
                                 std::to_wstring(GetCurrentProcessId());
  DeleteFileW(temporary.c_str());
  if (!WriteUtf8File(temporary, content)) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  if (!MoveFileExW(temporary.c_str(), path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

std::vector<std::wstring> Split(const std::wstring& value, wchar_t delimiter) {
  std::vector<std::wstring> result;
  size_t start = 0;
  while (true) {
    const size_t end = value.find(delimiter, start);
    result.push_back(value.substr(
        start, end == std::wstring::npos ? std::wstring::npos : end - start));
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  return result;
}

std::vector<std::wstring> Lines(const std::wstring& value) {
  auto lines = Split(value, L'\n');
  for (auto& line : lines) {
    if (!line.empty() && line.back() == L'\r') line.pop_back();
  }
  if (!lines.empty() && lines.back().empty()) lines.pop_back();
  return lines;
}

bool ReadDeltaInventory(const std::wstring& path,
                        bool has_change_type,
                        std::map<std::wstring, DeltaFile>* inventory) {
  std::wstring text;
  if (!ReadUtf8File(path, &text)) return false;
  for (const auto& line : Lines(text)) {
    if (line.empty()) return false;
    const auto columns = Split(line, L'\t');
    if (columns.size() != (has_change_type ? 4u : 3u) ||
        !HasValidRelativePath(columns[0]) || !IsSha256(columns[2])) {
      return false;
    }
    unsigned long long size = 0;
    try {
      size = std::stoull(columns[1]);
    } catch (...) {
      return false;
    }
    DeltaFile file{columns[0], size, Lower(columns[2]),
                   has_change_type ? columns[3] : L""};
    if (has_change_type && file.change_type != L"added" &&
        file.change_type != L"modified") {
      return false;
    }
    const auto key = Lower(file.path);
    if (!inventory->emplace(key, std::move(file)).second) return false;
  }
  return !inventory->empty();
}

bool ReadRemovedPaths(const std::wstring& path,
                      std::set<std::wstring>* removed) {
  std::wstring text;
  if (!ReadUtf8File(path, &text)) return false;
  for (const auto& line : Lines(text)) {
    if (!HasValidRelativePath(line) || !removed->insert(Lower(line)).second) {
      return false;
    }
  }
  return true;
}

bool SafeContainedPath(const std::wstring& root,
                       const std::wstring& relative,
                       std::wstring* output,
                       bool reject_reparse) {
  if (!HasValidRelativePath(relative)) return false;
  const auto root_path = FullPath(root);
  if (root_path.empty()) return false;
  std::wstring converted = relative;
  std::replace(converted.begin(), converted.end(), L'/', L'\\');
  const auto candidate = FullPath(root_path + L"\\" + converted);
  if (candidate.empty() || !IsWithin(root_path, candidate)) return false;
  if (reject_reparse) {
    auto current = std::filesystem::path(root_path);
    for (const auto& component : std::filesystem::path(converted)) {
      current /= component;
      const DWORD attributes = GetFileAttributesW(current.c_str());
      if (attributes != INVALID_FILE_ATTRIBUTES &&
          (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        return false;
      }
    }
  }
  *output = candidate;
  return true;
}

bool EnsureSafeParentDirectories(const std::wstring& root,
                                 const std::wstring& relative) {
  if (!HasValidRelativePath(relative)) return false;
  const auto root_path = FullPath(root);
  if (root_path.empty()) return false;
  auto current = std::filesystem::path(root_path);
  std::wstring converted = relative;
  std::replace(converted.begin(), converted.end(), L'/', L'\\');
  auto components = Split(converted, L'\\');
  for (size_t index = 0; index + 1 < components.size(); ++index) {
    current /= components[index];
    const DWORD attributes = GetFileAttributesW(current.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
      if (!CreateDirectoryW(current.c_str(), nullptr) &&
          GetLastError() != ERROR_ALREADY_EXISTS) {
        return false;
      }
    } else if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
               (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      return false;
    }
  }
  return true;
}

bool VerifyDeltaInventory(const std::wstring& root,
                          const std::map<std::wstring, DeltaFile>& inventory) {
  for (const auto& [key, entry] : inventory) {
    std::wstring file_path;
    if (!SafeContainedPath(root, entry.path, &file_path, true)) return false;
    const DWORD attributes = GetFileAttributesW(file_path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      return false;
    }
    WIN32_FILE_ATTRIBUTE_DATA data{};
    if (!GetFileAttributesExW(file_path.c_str(), GetFileExInfoStandard, &data)) {
      return false;
    }
    const unsigned long long size =
        (static_cast<unsigned long long>(data.nFileSizeHigh) << 32) |
        data.nFileSizeLow;
    if (size != entry.size || Lower(Sha256File(file_path)) != entry.sha256) {
      return false;
    }
  }
  return true;
}

bool CopyFileAtomicVerified(const std::wstring& source,
                            const std::wstring& destination,
                            const std::wstring& expected_hash,
                            std::wstring* failure_stage = nullptr,
                            DWORD* failure_error = nullptr,
                            std::wstring* actual_hash = nullptr) {
  if (failure_stage != nullptr) failure_stage->clear();
  if (failure_error != nullptr) *failure_error = ERROR_SUCCESS;
  if (actual_hash != nullptr) actual_hash->clear();
  const auto fail = [&](const wchar_t* stage, DWORD error) {
    if (failure_stage != nullptr) *failure_stage = stage;
    if (failure_error != nullptr) *failure_error = error;
    return false;
  };
  const auto temporary = destination + L".suelosar-tmp-" +
                         std::to_wstring(GetCurrentProcessId());
  if (!DeleteFileW(temporary.c_str())) {
    const DWORD error = GetLastError();
    if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) {
      return fail(L"remove_stale_temporary", error);
    }
  }
  if (!CopyFileW(source.c_str(), temporary.c_str(), FALSE)) {
    const DWORD error = GetLastError();
    DeleteFileW(temporary.c_str());
    return fail(L"copy_to_temporary", error);
  }
  const std::wstring copied_hash = Lower(Sha256File(temporary));
  if (actual_hash != nullptr) *actual_hash = copied_hash;
  if (copied_hash != Lower(expected_hash)) {
    DeleteFileW(temporary.c_str());
    return fail(L"temporary_hash_mismatch", ERROR_SUCCESS);
  }
  if (!MoveFileExW(temporary.c_str(), destination.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    const DWORD error = GetLastError();
    DeleteFileW(temporary.c_str());
    return fail(L"replace_destination", error);
  }
  return true;
}

bool IsElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  const bool result = GetTokenInformation(token, TokenElevation, &elevation,
                                          sizeof(elevation), &size) != 0 &&
                      elevation.TokenIsElevated != 0;
  CloseHandle(token);
  return result;
}

bool GetDeltaPaths(const std::vector<std::wstring>& args, DeltaPaths* paths) {
  if (args.size() != 24) return false;
  paths->update_directory = FullPath(args[2]);
  paths->staging_directory = FullPath(args[3]);
  paths->apply_list = FullPath(args[4]);
  paths->apply_hash = Lower(args[5]);
  paths->remove_list = FullPath(args[6]);
  paths->remove_hash = Lower(args[7]);
  paths->target_manifest = FullPath(args[8]);
  paths->target_manifest_hash = Lower(args[9]);
  paths->previous_manifest = FullPath(args[10]);
  paths->previous_manifest_hash = Lower(args[11]);
  paths->target_verify_list = FullPath(args[12]);
  paths->target_verify_hash = Lower(args[13]);
  paths->previous_verify_list = FullPath(args[14]);
  paths->previous_verify_hash = Lower(args[15]);
  paths->local_manifest = FullPath(args[16]);
  paths->install_directory = FullPath(args[17]);
  paths->app_path = FullPath(args[18]);
  paths->baseline_version = args[19];
  paths->target_version = args[20];
  paths->installation_id = args[21];
  try {
    paths->parent_pid = static_cast<DWORD>(std::stoul(args[22]));
  } catch (...) {
    return false;
  }
  paths->helper_directory = FullPath(args[23]);
  return !paths->update_directory.empty() &&
         !paths->staging_directory.empty() && !paths->apply_list.empty() &&
         !paths->remove_list.empty() && !paths->target_manifest.empty() &&
         !paths->previous_manifest.empty() &&
         !paths->target_verify_list.empty() &&
         !paths->previous_verify_list.empty() &&
         !paths->local_manifest.empty() &&
         !paths->install_directory.empty() && !paths->app_path.empty() &&
         !paths->helper_directory.empty() && IsSha256(paths->apply_hash) &&
         IsSha256(paths->remove_hash) && IsSha256(paths->target_manifest_hash) &&
         IsSha256(paths->previous_manifest_hash) &&
         IsSha256(paths->target_verify_hash) &&
         IsSha256(paths->previous_verify_hash) &&
         paths->installation_id.size() == 36 &&
         IsStableVersion(paths->baseline_version) &&
         IsStableVersion(paths->target_version);
}

bool HasJsonStringField(const std::wstring& json, const std::wstring& key,
                        const std::wstring& expected) {
  const std::wstring token = L"\"" + key + L"\"";
  size_t position = 0;
  while ((position = json.find(token, position)) != std::wstring::npos) {
    position += token.size();
    while (position < json.size() && iswspace(json[position])) ++position;
    if (position >= json.size() || json[position++] != L':') continue;
    while (position < json.size() && iswspace(json[position])) ++position;
    if (position >= json.size() || json[position++] != L'"') continue;
    const size_t value_end = json.find(L'"', position);
    if (value_end == std::wstring::npos) return false;
    if (json.compare(position, value_end - position, expected) == 0 &&
        value_end - position == expected.size()) {
      return true;
    }
    position = value_end + 1;
  }
  return false;
}

bool HasJsonNumberField(const std::wstring& json, const std::wstring& key,
                        const std::wstring& expected) {
  const std::wstring token = L"\"" + key + L"\"";
  size_t position = 0;
  while ((position = json.find(token, position)) != std::wstring::npos) {
    position += token.size();
    while (position < json.size() && iswspace(json[position])) ++position;
    if (position >= json.size() || json[position++] != L':') continue;
    while (position < json.size() && iswspace(json[position])) ++position;
    const size_t value_start = position;
    while (position < json.size() && json[position] >= L'0' &&
           json[position] <= L'9') {
      ++position;
    }
    if (position == value_start ||
        json.compare(value_start, position - value_start, expected) != 0 ||
        position - value_start != expected.size()) {
      continue;
    }
    while (position < json.size() && iswspace(json[position])) ++position;
    if (position < json.size() &&
        (json[position] == L',' || json[position] == L'}')) {
      return true;
    }
  }
  return false;
}

bool HasExpectedVersionFields(const std::wstring& manifest_text,
                              const std::wstring& version,
                              const std::wstring& installation_id) {
  StableVersion parsed;
  if (!ParseStableVersion(version, &parsed)) return false;
  const std::wstring semantic = std::to_wstring(parsed.major) + L"." +
                                std::to_wstring(parsed.minor) + L"." +
                                std::to_wstring(parsed.patch);
  return parsed.has_build &&
         HasJsonStringField(manifest_text, L"app_version", semantic) &&
         HasJsonNumberField(manifest_text, L"build_number",
                            std::to_wstring(parsed.build)) &&
         HasJsonStringField(manifest_text, L"installation_id",
                            installation_id);
}

bool ProcessImageMatches(DWORD process_id, const std::wstring& expected_path) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                              process_id);
  if (process == nullptr) return false;
  std::vector<wchar_t> buffer(32768);
  DWORD length = static_cast<DWORD>(buffer.size());
  const bool queried = QueryFullProcessImageNameW(process, 0, buffer.data(),
                                                   &length) != 0;
  CloseHandle(process);
  return queried && Lower(FullPath(std::wstring(buffer.data(), length))) ==
                        Lower(FullPath(expected_path));
}

bool ValidateDifferential(const DeltaPaths& paths, bool verify_baseline) {
  const auto update_root = PersistentUpdateRoot();
  if (update_root.empty() || !IsDirectChild(update_root, paths.update_directory) ||
      !IsNamedDirectory(paths.update_directory, kUpdateDirectoryPrefix) ||
      Lower(paths.staging_directory) !=
          Lower(FullPath(paths.update_directory + L"\\staged")) ||
      !IsWithin(paths.update_directory, paths.apply_list) ||
      !IsWithin(paths.update_directory, paths.remove_list) ||
      !IsWithin(paths.update_directory, paths.target_manifest) ||
      !IsWithin(paths.update_directory, paths.previous_manifest) ||
      !IsWithin(paths.update_directory, paths.target_verify_list) ||
      !IsWithin(paths.update_directory, paths.previous_verify_list) ||
      !IsWithin(paths.update_directory, paths.staging_directory) ||
      Lower(std::filesystem::path(paths.app_path).filename().wstring()) !=
          Lower(kAppName) ||
      Lower(paths.install_directory) != Lower(ParentPath(paths.app_path)) ||
      Lower(ResolveInstalledAppPath()) != Lower(paths.app_path) ||
      !IsNamedDirectory(paths.helper_directory, kHelperDirectoryPrefix)) {
    return false;
  }
  const DWORD attributes = GetFileAttributesW(paths.helper_directory.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }
  wchar_t temp_path[MAX_PATH]{};
  const DWORD temp_length = GetTempPathW(MAX_PATH, temp_path);
  if (temp_length == 0 || temp_length >= MAX_PATH ||
      !IsWithin(temp_path, paths.helper_directory)) {
    return false;
  }
  const auto expected_manifest = FullPath(
      PersistentUpdateRoot() + L"\\..\\Manifests\\installation-manifest.json");
  if (Lower(expected_manifest) != Lower(paths.local_manifest)) return false;

  const std::wstring current_helper = [&]() {
    std::vector<wchar_t> buffer(32768);
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                             static_cast<DWORD>(buffer.size()));
    return length == 0 || length >= buffer.size()
               ? std::wstring()
               : FullPath(std::wstring(buffer.data(), length));
  }();
  if (current_helper.empty() ||
      !IsDirectChild(paths.helper_directory, current_helper)) {
    return false;
  }
  const auto local_attributes = GetFileAttributesW(paths.local_manifest.c_str());
  if (local_attributes == INVALID_FILE_ATTRIBUTES ||
      (local_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      Sha256File(paths.local_manifest) != paths.previous_manifest_hash ||
      Sha256File(paths.previous_manifest) != paths.previous_manifest_hash ||
      Sha256File(paths.apply_list) != paths.apply_hash ||
      Sha256File(paths.remove_list) != paths.remove_hash ||
      Sha256File(paths.target_manifest) != paths.target_manifest_hash ||
      Sha256File(paths.target_verify_list) != paths.target_verify_hash ||
      Sha256File(paths.previous_verify_list) != paths.previous_verify_hash) {
    return false;
  }
  std::wstring local_text;
  std::wstring previous_text;
  std::wstring target_text;
  if (!ReadUtf8File(paths.local_manifest, &local_text) ||
      !ReadUtf8File(paths.previous_manifest, &previous_text) ||
      !ReadUtf8File(paths.target_manifest, &target_text) ||
      local_text != previous_text ||
      !HasExpectedVersionFields(local_text, paths.baseline_version,
                                paths.installation_id) ||
      !HasExpectedVersionFields(target_text, paths.target_version,
                                paths.installation_id) ||
      !VersionMatches(paths.app_path, paths.baseline_version)) {
    return false;
  }
  std::map<std::wstring, DeltaFile> apply;
  std::map<std::wstring, DeltaFile> target;
  std::map<std::wstring, DeltaFile> previous;
  std::set<std::wstring> removed;
  if (!ReadDeltaInventory(paths.apply_list, true, &apply) ||
      !ReadDeltaInventory(paths.target_verify_list, false, &target) ||
      !ReadDeltaInventory(paths.previous_verify_list, false, &previous) ||
      !ReadRemovedPaths(paths.remove_list, &removed)) {
    return false;
  }
  for (const auto& [key, file] : apply) {
    const auto target_file = target.find(key);
    const auto previous_file = previous.find(key);
    if (target_file == target.end() ||
        target_file->second.size != file.size ||
        target_file->second.sha256 != file.sha256 ||
        (file.change_type == L"added" && previous_file != previous.end()) ||
        (file.change_type == L"modified" && previous_file == previous.end())) {
      return false;
    }
  }
  for (const auto& key : removed) {
    if (previous.find(key) == previous.end() || target.find(key) != target.end()) {
      return false;
    }
  }
  for (const auto& [key, old_file] : previous) {
    const auto new_file = target.find(key);
    if (new_file == target.end()) {
      if (removed.find(key) == removed.end()) return false;
    } else if ((old_file.size != new_file->second.size ||
                old_file.sha256 != new_file->second.sha256) &&
               apply.find(key) == apply.end()) {
      return false;
    }
  }
  for (const auto& [key, new_file] : target) {
    if (previous.find(key) == previous.end() && apply.find(key) == apply.end()) {
      return false;
    }
  }
  std::set<std::wstring> staged;
  std::error_code error;
  for (std::filesystem::recursive_directory_iterator it(
           paths.staging_directory, error), end;
       !error && it != end; it.increment(error)) {
    const DWORD item_attributes = GetFileAttributesW(it->path().c_str());
    if (item_attributes == INVALID_FILE_ATTRIBUTES ||
        (item_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      return false;
    }
    if (it->is_directory(error)) continue;
    if (error) return false;
    const auto relative = std::filesystem::relative(it->path(),
                                                    paths.staging_directory,
                                                    error)
                              .generic_wstring();
    if (error || !HasValidRelativePath(relative) ||
        !staged.insert(Lower(relative)).second) {
      return false;
    }
  }
  if (error || staged.size() != apply.size()) return false;
  for (const auto& [key, file] : apply) {
    std::wstring staged_path;
    if (!SafeContainedPath(paths.staging_directory, file.path, &staged_path,
                           true)) {
      return false;
    }
    const auto staged_attributes = GetFileAttributesW(staged_path.c_str());
    WIN32_FILE_ATTRIBUTE_DATA data{};
    if (staged.find(key) == staged.end() ||
        staged_attributes == INVALID_FILE_ATTRIBUTES ||
        (staged_attributes &
         (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
        !GetFileAttributesExW(staged_path.c_str(), GetFileExInfoStandard, &data)) {
      return false;
    }
    const unsigned long long size =
        (static_cast<unsigned long long>(data.nFileSizeHigh) << 32) |
        data.nFileSizeLow;
    if (size != file.size || Lower(Sha256File(staged_path)) != file.sha256) {
      return false;
    }
  }
  if (verify_baseline &&
      (!VersionMatches(paths.app_path, paths.baseline_version) ||
       !VerifyDeltaInventory(paths.install_directory, previous))) {
    return false;
  }
  return true;
}

std::wstring TransactionDirectory(const DeltaPaths& paths) {
  return paths.update_directory + L"\\rollback";
}

std::wstring TransactionStatePath(const DeltaPaths& paths) {
  return TransactionDirectory(paths) + L"\\transaction.state";
}

std::wstring TransactionJournalPath(const DeltaPaths& paths) {
  return TransactionDirectory(paths) + L"\\journal.tsv";
}

std::wstring RecoveryToken(const DeltaPaths& paths) {
  if (paths.update_directory.empty()) return {};
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_length = 0;
  DWORD bytes_read = 0;
  DWORD hash_length = 0;
  std::vector<UCHAR> hash_object;
  std::vector<UCHAR> digest;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                  0) != 0) {
    return {};
  }
  bool succeeded =
      BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_length),
                        sizeof(object_length), &bytes_read, 0) == 0 &&
      BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
                        reinterpret_cast<PUCHAR>(&hash_length),
                        sizeof(hash_length), &bytes_read, 0) == 0;
  if (succeeded) {
    hash_object.resize(object_length);
    digest.resize(hash_length);
    succeeded = BCryptCreateHash(algorithm, &hash, hash_object.data(),
                                 object_length, nullptr, 0, 0) == 0;
  }
  if (succeeded) {
    const auto& value = paths.update_directory;
    succeeded = BCryptHashData(
                    hash, reinterpret_cast<PUCHAR>(
                              const_cast<wchar_t*>(value.data())),
                    static_cast<ULONG>(value.size() * sizeof(wchar_t)), 0) ==
                    0 &&
                BCryptFinishHash(hash, digest.data(), hash_length, 0) == 0;
  }
  std::wstring token;
  if (succeeded && digest.size() >= 16) {
    static constexpr wchar_t digits[] = L"0123456789abcdef";
    token.reserve(32);
    for (size_t index = 0; index < 16; ++index) {
      token.push_back(digits[digest[index] >> 4]);
      token.push_back(digits[digest[index] & 0x0F]);
    }
  }
  if (hash != nullptr) BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  return token;
}

std::wstring RecoveryPayloadDirectory(const DeltaPaths& paths) {
  std::array<wchar_t, 32768> program_data{};
  const DWORD length = GetEnvironmentVariableW(
      L"ProgramData", program_data.data(),
      static_cast<DWORD>(program_data.size()));
  const auto token = RecoveryToken(paths);
  if (length == 0 || length >= program_data.size() || token.empty()) {
    return {};
  }
  return std::wstring(program_data.data(), length) +
         L"\\SuelosAR-DifferentialRecovery\\" + token;
}

std::wstring RecoveryHelperPath(const DeltaPaths& paths) {
  const auto directory = RecoveryPayloadDirectory(paths);
  return directory.empty() ? std::wstring()
                           : directory + L"\\suelosar_update_helper.exe";
}

std::wstring RecoveryArgumentsPath(const DeltaPaths& paths) {
  const auto directory = RecoveryPayloadDirectory(paths);
  return directory.empty() ? std::wstring()
                           : directory + L"\\recovery.args";
}

std::wstring RecoveryTaskName(const DeltaPaths& paths) {
  const auto token = RecoveryToken(paths);
  return token.empty() ? std::wstring()
                       : L"SuelosAR-Differential-Recovery-" + token;
}

bool EnsureRecoveryPayloadDirectory(const DeltaPaths& paths) {
  const auto directory = RecoveryPayloadDirectory(paths);
  if (directory.empty()) return false;
  const auto root = std::filesystem::path(directory).parent_path().wstring();
  std::error_code error;
  std::filesystem::create_directories(root, error);
  if (error) return false;
  auto secure_directory = [](const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) !=
            FILE_ATTRIBUTE_DIRECTORY) {
      return false;
    }
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1,
            &descriptor, nullptr)) {
      return false;
    }
    const BOOL secured = SetFileSecurityW(
        path.c_str(), DACL_SECURITY_INFORMATION |
                          PROTECTED_DACL_SECURITY_INFORMATION,
        descriptor);
    LocalFree(descriptor);
    return secured != FALSE;
  };
  if (!secure_directory(root)) return false;
  std::filesystem::create_directory(directory, error);
  if (error && error != std::errc::file_exists) return false;
  if (!secure_directory(directory)) return false;
  const DWORD attributes = GetFileAttributesW(directory.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ==
             FILE_ATTRIBUTE_DIRECTORY;
}

bool DeleteRecoveryPayload(const DeltaPaths& paths) {
  const auto directory = RecoveryPayloadDirectory(paths);
  if (directory.empty()) return false;
  const auto helper = RecoveryHelperPath(paths);
  const auto arguments = RecoveryArgumentsPath(paths);
  if (GetFileAttributesW(directory.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return true;
  }
  if (!DeleteFileW(helper.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) {
    return false;
  }
  if (!DeleteFileW(arguments.c_str()) &&
      GetLastError() != ERROR_FILE_NOT_FOUND) {
    return false;
  }
  return RemoveDirectoryW(directory.c_str()) != 0 ||
         GetLastError() == ERROR_FILE_NOT_FOUND;
}

bool RunTaskScheduler(const std::wstring& arguments) {
  std::vector<wchar_t> system_directory(32768);
  const UINT system_length = GetSystemDirectoryW(
      system_directory.data(), static_cast<UINT>(system_directory.size()));
  if (system_length == 0 || system_length >= system_directory.size()) {
    return false;
  }
  const std::wstring executable =
      std::wstring(system_directory.data(), system_length) + L"\\schtasks.exe";
  std::wstring command = QuoteArgument(executable) + L" " + arguments;
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr) return false;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_information{};
  job_information.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                               &job_information, sizeof(job_information))) {
    CloseHandle(job);
    return false;
  }
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), mutable_command.data(), nullptr,
                      nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                      &startup, &process)) {
    CloseHandle(job);
    return false;
  }
  CloseHandle(process.hThread);
  const bool assigned_to_job = AssignProcessToJobObject(job, process.hProcess) != 0;
  const DWORD wait = WaitForSingleObject(process.hProcess, 30000);
  DWORD exit_code = 1;
  bool succeeded = wait == WAIT_OBJECT_0 &&
                   GetExitCodeProcess(process.hProcess, &exit_code) &&
                   exit_code == 0;
  if (wait == WAIT_TIMEOUT && assigned_to_job) {
    CloseHandle(job);
    job = nullptr;
    succeeded = WaitForSingleObject(process.hProcess, 5000) == WAIT_OBJECT_0 &&
                GetExitCodeProcess(process.hProcess, &exit_code) &&
                exit_code == 0;
  } else if (wait == WAIT_TIMEOUT) {
    succeeded = WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0 &&
                GetExitCodeProcess(process.hProcess, &exit_code) &&
                exit_code == 0;
  }
  CloseHandle(process.hProcess);
  if (job != nullptr) CloseHandle(job);
  return succeeded;
}

bool DeleteRecoveryTask(const DeltaPaths& paths,
                        bool remove_payload = false) {
  const auto task_name = RecoveryTaskName(paths);
  if (task_name.empty()) return false;
  const std::wstring arguments =
      L"/Delete /TN " + QuoteArgument(task_name) + L" /F";
  if (!RunTaskScheduler(arguments)) return false;
  return !remove_payload || DeleteRecoveryPayload(paths);
}

bool CreateRecoveryTask(const DeltaPaths& paths,
                       const std::vector<std::wstring>& args) {
  if (args.size() != 24) return false;
  const auto payload_directory = RecoveryPayloadDirectory(paths);
  const auto recovery_helper = RecoveryHelperPath(paths);
  const auto recovery_args = RecoveryArgumentsPath(paths);
  const auto installed_helper =
      paths.helper_directory + L"\\" + kHelperName;
  if (!EnsureRecoveryPayloadDirectory(paths)) return false;
  const auto helper_hash = Sha256File(installed_helper);
  if (!IsSha256(helper_hash) ||
      !CopyFileW(installed_helper.c_str(), recovery_helper.c_str(), FALSE) ||
      Lower(Sha256File(recovery_helper)) != Lower(helper_hash)) {
    DeleteRecoveryPayload(paths);
    return false;
  }

  std::wstring saved_arguments;
  for (size_t index = 2; index < args.size(); ++index) {
    const auto& value = index == 22 ? std::wstring(L"0") : args[index];
    if (value.empty() || value.find_first_of(L"\r\n") != std::wstring::npos) {
      DeleteRecoveryPayload(paths);
      return false;
    }
    saved_arguments += value + L"\r\n";
  }
  if (!WriteUtf8File(recovery_args, saved_arguments)) {
    DeleteRecoveryPayload(paths);
    return false;
  }
  const std::wstring task_action =
      QuoteArgument(recovery_helper) + L" " +
      QuoteArgument(L"--differential-recovery") + L" " +
      QuoteArgument(recovery_args);
  if (task_action.size() > 261) {
    DeleteRecoveryPayload(paths);
    return false;
  }
  const auto task_name = RecoveryTaskName(paths);
  const std::wstring create_arguments =
      L"/Create /TN " + QuoteArgument(task_name) +
      L" /SC ONSTART /RU SYSTEM /RL HIGHEST /TR " +
      QuoteArgument(task_action) + L" /F";
  if (RunTaskScheduler(create_arguments)) return true;
  DeleteRecoveryPayload(paths);
  return false;
}

bool CopyToRollback(const DeltaPaths& paths,
                    const std::wstring& source,
                    const std::wstring& relative) {
  if (!EnsureSafeParentDirectories(TransactionDirectory(paths), relative)) {
    return false;
  }
  std::wstring backup;
  if (!SafeContainedPath(TransactionDirectory(paths), relative, &backup, true)) {
    return false;
  }
  return CopyFileW(source.c_str(), backup.c_str(), FALSE) != 0;
}

void AppendDifferentialLog(const DeltaPaths& paths, const std::string& message);

void AppendAtomicCopyFailure(const DeltaPaths& paths,
                             const std::string& event,
                             const std::wstring& relative_path,
                             const std::wstring& failure_stage,
                             DWORD failure_error,
                             const std::wstring& expected_hash,
                             const std::wstring& actual_hash);

bool RestoreJournal(const DeltaPaths& paths,
                    const std::map<std::wstring, DeltaFile>& previous) {
  std::wstring journal;
  if (!ReadUtf8File(TransactionJournalPath(paths), &journal)) {
    AppendDifferentialLog(paths, "rollback_journal_read_failed");
    return false;
  }
  bool all_files_restored = true;
  for (const auto& line : Lines(journal)) {
    const auto columns = Split(line, L'\t');
    if (columns.size() != 2 || !HasValidRelativePath(columns[0]) ||
        (columns[1] != L"0" && columns[1] != L"1")) {
      AppendDifferentialLog(paths, "rollback_journal_entry_invalid");
      all_files_restored = false;
      continue;
    }
    const auto key = Lower(columns[0]);
    std::wstring destination;
    if (!SafeContainedPath(paths.install_directory, columns[0], &destination,
                           true)) {
      AppendDifferentialLog(paths, "rollback_destination_path_rejected;path=" +
                                       WideToUtf8(columns[0]));
      all_files_restored = false;
      continue;
    }
    if (columns[1] == L"1") {
      std::wstring backup;
      if (!SafeContainedPath(TransactionDirectory(paths), columns[0], &backup,
                             true)) {
        AppendDifferentialLog(paths, "rollback_backup_path_rejected;path=" +
                                         WideToUtf8(columns[0]));
        all_files_restored = false;
        continue;
      }
      const auto old = previous.find(key);
      if (old == previous.end()) {
        AppendDifferentialLog(paths, "rollback_previous_inventory_entry_missing;path=" +
                                         WideToUtf8(columns[0]));
        all_files_restored = false;
        continue;
      }
      const std::wstring backup_hash = Lower(Sha256File(backup));
      if (backup_hash != old->second.sha256) {
        AppendDifferentialLog(paths, "rollback_backup_hash_mismatch;path=" +
                                         WideToUtf8(columns[0]) +
                                         ";expected=" + WideToUtf8(old->second.sha256) +
                                         ";actual=" + WideToUtf8(backup_hash));
        all_files_restored = false;
        continue;
      }
      if (!EnsureSafeParentDirectories(paths.install_directory, columns[0])) {
        const DWORD error = GetLastError();
        AppendDifferentialLog(paths, "rollback_parent_directory_failed;path=" +
                                         WideToUtf8(columns[0]) +
                                         ";win32=" + std::to_string(error));
        all_files_restored = false;
        continue;
      }
      std::wstring failure_stage;
      std::wstring actual_hash;
      DWORD failure_error = ERROR_SUCCESS;
      if (!CopyFileAtomicVerified(backup, destination, old->second.sha256,
                                  &failure_stage, &failure_error, &actual_hash)) {
        AppendAtomicCopyFailure(paths, "rollback_file_restore_failed",
                                columns[0], failure_stage, failure_error,
                                old->second.sha256, actual_hash);
        all_files_restored = false;
        continue;
      }
    } else {
      const DWORD attributes = GetFileAttributesW(destination.c_str());
      if (attributes != INVALID_FILE_ATTRIBUTES) {
        if ((attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
            !DeleteFileW(destination.c_str())) {
          const DWORD error = GetLastError();
          AppendDifferentialLog(paths, "rollback_new_file_removal_failed;path=" +
                                           WideToUtf8(columns[0]) +
                                           ";win32=" + std::to_string(error));
          all_files_restored = false;
        }
      }
    }
  }
  if (!all_files_restored) return false;
  const std::wstring manifest_backup =
      TransactionDirectory(paths) + L"\\installation-manifest.json";
  std::wstring manifest_failure_stage;
  std::wstring manifest_actual_hash;
  DWORD manifest_failure_error = ERROR_SUCCESS;
  if (!CopyFileAtomicVerified(manifest_backup, paths.local_manifest,
                              paths.previous_manifest_hash,
                              &manifest_failure_stage, &manifest_failure_error,
                              &manifest_actual_hash)) {
    AppendAtomicCopyFailure(paths, "rollback_manifest_restore_failed",
                            L"installation-manifest.json",
                            manifest_failure_stage, manifest_failure_error,
                            paths.previous_manifest_hash, manifest_actual_hash);
    return false;
  }
  std::map<std::wstring, DeltaFile> current_previous;
  if (!ReadDeltaInventory(paths.previous_verify_list, false,
                          &current_previous)) {
    AppendDifferentialLog(paths, "rollback_previous_inventory_read_failed");
    return false;
  }
  if (!VerifyDeltaInventory(paths.install_directory, current_previous)) {
    AppendDifferentialLog(paths, "rollback_previous_inventory_verify_failed");
    return false;
  }
  if (Sha256File(paths.local_manifest) != paths.previous_manifest_hash) {
    AppendDifferentialLog(paths, "rollback_manifest_hash_verify_failed");
    return false;
  }
  if (!WriteAtomicUtf8File(TransactionStatePath(paths), L"rolled-back\r\n")) {
    const DWORD error = GetLastError();
    AppendDifferentialLog(paths, "rollback_state_write_failed;win32=" +
                                     std::to_string(error));
    return false;
  }
  return true;
}

void AppendDifferentialLog(const DeltaPaths& paths, const std::string& message) {
  std::ofstream log(std::filesystem::path(paths.update_directory +
                                         L"\\differential-update.log"),
                    std::ios::binary | std::ios::app);
  if (!log) return;
  log << message << "\r\n";
  log.flush();
}

void AppendAtomicCopyFailure(const DeltaPaths& paths,
                             const std::string& event,
                             const std::wstring& relative_path,
                             const std::wstring& failure_stage,
                             DWORD failure_error,
                             const std::wstring& expected_hash,
                             const std::wstring& actual_hash) {
  std::string message = event + ";path=" + WideToUtf8(relative_path) +
                        ";stage=" + WideToUtf8(failure_stage) +
                        ";win32=" + std::to_string(failure_error);
  if (!expected_hash.empty()) {
    message += ";expected=" + WideToUtf8(expected_hash);
  }
  if (!actual_hash.empty()) {
    message += ";actual=" + WideToUtf8(actual_hash);
  }
  AppendDifferentialLog(paths, message);
}

int ApplyDifferential(const DeltaPaths& paths,
                      const std::vector<std::wstring>& args) {
  if (!IsElevated()) return 12;
  if (HasAnotherAppProcess(paths.app_path, 0)) {
    AppendDifferentialLog(paths, "application_still_running_before_apply");
    return 14;
  }
  HANDLE mutex = CreateMutexW(nullptr, FALSE,
                              L"Local\\SuelosAR-DifferentialUpdate-v1");
  if (mutex == nullptr || GetLastError() == ERROR_ALREADY_EXISTS) {
    if (mutex != nullptr) CloseHandle(mutex);
    return 13;
  }
  const bool valid = ValidateDifferential(paths, true);
  if (!valid) {
    CloseHandle(mutex);
    AppendDifferentialLog(paths, "validation_failed");
    return 14;
  }
  const auto rollback_directory = TransactionDirectory(paths);
  std::error_code error;
  if (std::filesystem::exists(rollback_directory, error) || error ||
      !std::filesystem::create_directory(rollback_directory, error) || error) {
    CloseHandle(mutex);
    AppendDifferentialLog(paths, "rollback_directory_unavailable");
    return 15;
  }
  std::map<std::wstring, DeltaFile> previous;
  std::map<std::wstring, DeltaFile> target;
  std::map<std::wstring, DeltaFile> apply;
  std::set<std::wstring> removed;
  if (!ReadDeltaInventory(paths.previous_verify_list, false, &previous) ||
      !ReadDeltaInventory(paths.target_verify_list, false, &target) ||
      !ReadDeltaInventory(paths.apply_list, true, &apply) ||
      !ReadRemovedPaths(paths.remove_list, &removed)) {
    CloseHandle(mutex);
    AppendDifferentialLog(paths, "inventory_parse_failed");
    return 16;
  }
  std::set<std::wstring> affected;
  for (const auto& [key, file] : apply) affected.insert(key);
  affected.insert(removed.begin(), removed.end());
  std::wstring journal;
  for (const auto& key : affected) {
    const auto target_file = apply.find(key);
    const auto old_file = previous.find(key);
    const auto relative = target_file != apply.end()
                              ? target_file->second.path
                              : (old_file != previous.end()
                                     ? old_file->second.path
                                     : std::wstring());
    std::wstring destination;
    if (relative.empty() ||
        !SafeContainedPath(paths.install_directory, relative, &destination,
                           true)) {
      CloseHandle(mutex);
      AppendDifferentialLog(paths, "destination_path_rejected");
      return 17;
    }
    const DWORD attributes = GetFileAttributesW(destination.c_str());
    const bool exists = attributes != INVALID_FILE_ATTRIBUTES;
    if (exists &&
        ((attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 ||
         old_file == previous.end())) {
      CloseHandle(mutex);
      AppendDifferentialLog(paths, "destination_not_managed_regular_file");
      return 18;
    }
    if (exists && !CopyToRollback(paths, destination, relative)) {
      CloseHandle(mutex);
      AppendDifferentialLog(paths, "backup_failed");
      return 19;
    }
    journal += relative + (exists ? L"\t1\r\n" : L"\t0\r\n");
  }
  const std::wstring manifest_backup =
      rollback_directory + L"\\installation-manifest.json";
  if (!CopyFileW(paths.local_manifest.c_str(), manifest_backup.c_str(), FALSE) ||
      Lower(Sha256File(manifest_backup)) != paths.previous_manifest_hash ||
      !WriteUtf8File(TransactionJournalPath(paths), journal) ||
      !WriteAtomicUtf8File(TransactionStatePath(paths), L"applying\r\n")) {
    CloseHandle(mutex);
    AppendDifferentialLog(paths, "journal_prepare_failed");
    return 20;
  }
  if (!CreateRecoveryTask(paths, args)) {
    WriteAtomicUtf8File(TransactionStatePath(paths),
                        L"aborted-before-apply\r\n");
    CloseHandle(mutex);
    AppendDifferentialLog(paths, "recovery_task_registration_failed");
    return 21;
  }
  bool succeeded = true;
  size_t applied_files = 0;
  for (const auto& [key, file] : apply) {
    std::wstring source;
    std::wstring destination;
    std::wstring failure_stage;
    std::wstring actual_hash;
    DWORD failure_error = ERROR_SUCCESS;
    if (!SafeContainedPath(paths.staging_directory, file.path, &source, true)) {
      failure_stage = L"staging_path_rejected";
    } else if (!SafeContainedPath(paths.install_directory, file.path,
                                  &destination, true)) {
      failure_stage = L"destination_path_rejected";
    } else if (!EnsureSafeParentDirectories(paths.install_directory,
                                            file.path)) {
      failure_stage = L"parent_directory_prepare_failed";
      failure_error = GetLastError();
    } else if (!CopyFileAtomicVerified(source, destination, file.sha256,
                                       &failure_stage, &failure_error,
                                       &actual_hash)) {
      // Detailed failure information is appended below.
    }
    if (!failure_stage.empty()) {
      succeeded = false;
      AppendAtomicCopyFailure(paths, "file_apply_failed", file.path,
                              failure_stage, failure_error, file.sha256,
                              actual_hash);
      break;
    }
    ++applied_files;
#if defined(SUELOSAR_QA_FAULT_INJECTION)
    wchar_t inject_value[8]{};
    const DWORD inject_length = GetEnvironmentVariableW(
        L"SUELOSAR_QA_INTERRUPT_AFTER_FIRST_FILE", inject_value,
        static_cast<DWORD>(std::size(inject_value)));
    if (applied_files == 1 && inject_length == 1 && inject_value[0] == L'1') {
      CloseHandle(mutex);
      AppendDifferentialLog(paths, "qa_injected_interruption_after_first_file");
      return 97;
    }
#endif
  }
  if (succeeded) {
    for (const auto& key : removed) {
      const auto old_file = previous.find(key);
      std::wstring destination;
      if (old_file == previous.end() ||
          !SafeContainedPath(paths.install_directory, old_file->second.path,
                             &destination, true) ||
          !DeleteFileW(destination.c_str())) {
        succeeded = false;
        AppendDifferentialLog(paths, "managed_removal_failed");
        break;
      }
    }
  }
  if (succeeded && !VerifyDeltaInventory(paths.install_directory, target)) {
    succeeded = false;
    AppendDifferentialLog(paths, "target_inventory_verification_failed");
  }
  if (succeeded &&
      (!CopyFileAtomicVerified(paths.target_manifest,
                               paths.local_manifest,
                               paths.target_manifest_hash) ||
       !HasExpectedVersionFields(
           [&]() { std::wstring text; ReadUtf8File(paths.local_manifest, &text); return text; }(),
           paths.target_version, paths.installation_id) ||
       !VersionMatches(paths.app_path, paths.target_version))) {
    succeeded = false;
    AppendDifferentialLog(paths, "target_manifest_or_version_failed");
  }
  if (succeeded &&
      WriteAtomicUtf8File(TransactionStatePath(paths), L"committed\r\n")) {
    CloseHandle(mutex);
    return 0;
  }
  const bool rolled_back = RestoreJournal(paths, previous);
  if (rolled_back && !DeleteRecoveryTask(paths, true)) {
    AppendDifferentialLog(paths, "recovery_task_cleanup_deferred_after_rollback");
  }
  CloseHandle(mutex);
  AppendDifferentialLog(paths, rolled_back ? "rollback_succeeded"
                                           : "rollback_failed");
  return rolled_back ? 10 : 11;
}

bool RunElevatedDifferential(const std::wstring& helper_path,
                             const std::vector<std::wstring>& args,
                             const std::wstring& mode,
                             DWORD* exit_code) {
  std::wstring parameters = QuoteArgument(mode);
  for (size_t index = 2; index < args.size(); ++index) {
    parameters += L" " + QuoteArgument(index == 22 ? L"0" : args[index]);
  }
  const std::wstring working_directory = ParentPath(helper_path);
  SHELLEXECUTEINFOW launch{};
  launch.cbSize = sizeof(launch);
  launch.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  launch.lpVerb = L"runas";
  launch.lpFile = helper_path.c_str();
  launch.lpParameters = parameters.c_str();
  launch.lpDirectory = working_directory.c_str();
  launch.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&launch) || launch.hProcess == nullptr) return false;
  WaitForSingleObject(launch.hProcess, INFINITE);
  const bool got_exit = GetExitCodeProcess(launch.hProcess, exit_code) != 0;
  CloseHandle(launch.hProcess);
  return got_exit;
}

int RunDifferentialWorker(const std::vector<std::wstring>& args,
                          bool rollback_only) {
  DeltaPaths paths;
  if (!GetDeltaPaths(args, &paths) || !IsElevated()) return 12;
  if (rollback_only) {
    if (HasAnotherAppProcess(paths.app_path, 0)) {
      AppendDifferentialLog(paths, "application_still_running_before_rollback");
      return 14;
    }
    HANDLE mutex = CreateMutexW(nullptr, FALSE,
                                L"Local\\SuelosAR-DifferentialUpdate-v1");
    if (mutex == nullptr || GetLastError() == ERROR_ALREADY_EXISTS) {
      if (mutex != nullptr) CloseHandle(mutex);
      return 13;
    }
    std::map<std::wstring, DeltaFile> previous;
    const bool loaded = ReadDeltaInventory(paths.previous_verify_list, false,
                                           &previous);
    const bool rolled_back = loaded && RestoreJournal(paths, previous);
    if (rolled_back && !DeleteRecoveryTask(paths, true)) {
      AppendDifferentialLog(paths, "recovery_task_cleanup_deferred_after_rollback");
    }
    CloseHandle(mutex);
    AppendDifferentialLog(paths, rolled_back ? "explicit_rollback_succeeded"
                                             : "explicit_rollback_failed");
    return rolled_back ? 0 : 11;
  }
  return ApplyDifferential(paths, args);
}

int RunDifferentialRecovery(const std::vector<std::wstring>& args) {
  if (args.size() != 3) return 12;
  const auto arguments_path = FullPath(args[2]);
  const DWORD argument_attributes = GetFileAttributesW(arguments_path.c_str());
  if (arguments_path.empty() || argument_attributes == INVALID_FILE_ATTRIBUTES ||
      (argument_attributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
    return 12;
  }
  std::error_code file_error;
  const auto argument_size =
      std::filesystem::file_size(arguments_path, file_error);
  if (file_error || argument_size > 65536) return 12;
  std::wstring saved_arguments;
  if (!ReadUtf8File(arguments_path, &saved_arguments)) return 12;
  const auto values = Lines(saved_arguments);
  if (values.size() != 22) return 12;
  std::vector<std::wstring> worker_args = {args[0], L"--differential-recovery"};
  worker_args.insert(worker_args.end(), values.begin(), values.end());
  DeltaPaths paths;
  if (!GetDeltaPaths(worker_args, &paths) || !IsElevated() ||
      Lower(arguments_path) != Lower(RecoveryArgumentsPath(paths))) {
    return 12;
  }
  std::vector<wchar_t> module_buffer(32768);
  const DWORD module_length = GetModuleFileNameW(
      nullptr, module_buffer.data(), static_cast<DWORD>(module_buffer.size()));
  if (module_length == 0 || module_length >= module_buffer.size() ||
      Lower(FullPath(std::wstring(module_buffer.data(), module_length))) !=
          Lower(RecoveryHelperPath(paths))) {
    return 12;
  }
  HANDLE mutex = CreateMutexW(nullptr, FALSE,
                              L"Local\\SuelosAR-DifferentialUpdate-v1");
  if (mutex == nullptr || GetLastError() == ERROR_ALREADY_EXISTS) {
    if (mutex != nullptr) CloseHandle(mutex);
    return 13;
  }
  std::error_code error;
  if (!std::filesystem::exists(paths.update_directory, error) && !error) {
    DeleteRecoveryTask(paths);
    CloseHandle(mutex);
    return 0;
  }
  if (error) {
    CloseHandle(mutex);
    return 14;
  }
  std::wstring state;
  if (!ReadUtf8File(TransactionStatePath(paths), &state)) {
    AppendDifferentialLog(paths, "startup_recovery_state_missing");
    CloseHandle(mutex);
    return 15;
  }
  while (!state.empty() && iswspace(state.back())) state.pop_back();
  if (state == L"committed" || state == L"rolled-back" ||
      state == L"aborted-before-apply") {
    if (!DeleteRecoveryTask(paths)) {
      AppendDifferentialLog(paths, "startup_recovery_task_cleanup_deferred");
    }
    AppendDifferentialLog(paths, "startup_recovery_noop_completed_transaction");
    CloseHandle(mutex);
    return 0;
  }
  if (state != L"applying") {
    AppendDifferentialLog(paths, "startup_recovery_unknown_transaction_state");
    CloseHandle(mutex);
    return 16;
  }
  if (HasAnotherAppProcess(paths.app_path, 0)) {
    AppendDifferentialLog(paths, "startup_recovery_application_running");
    CloseHandle(mutex);
    return 17;
  }
  std::map<std::wstring, DeltaFile> previous;
  const bool restored =
      ReadDeltaInventory(paths.previous_verify_list, false, &previous) &&
      RestoreJournal(paths, previous);
  if (!restored) {
    AppendDifferentialLog(paths, "startup_recovery_rollback_failed");
    CloseHandle(mutex);
    return 18;
  }
  if (!DeleteRecoveryTask(paths)) {
    AppendDifferentialLog(paths, "startup_recovery_task_cleanup_deferred");
  }
  AppendDifferentialLog(paths, "startup_recovery_rolled_back");
  CloseHandle(mutex);
  return 0;
}

int RunDifferentialBroker(const std::vector<std::wstring>& args) {
  DeltaPaths paths;
  if (!GetDeltaPaths(args, &paths) || paths.parent_pid == 0 ||
      !ValidateDifferential(paths, false) ||
      !ProcessImageMatches(paths.parent_pid, paths.app_path) ||
      HasAnotherAppProcess(paths.app_path, paths.parent_pid)) {
    WriteStatus("ERROR_DIFFERENTIAL_VALIDATION");
    return 2;
  }
  const HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, paths.parent_pid);
  if (parent == nullptr) {
    WriteStatus("ERROR_PARENT_PROCESS");
    return 2;
  }
  WriteStatus("READY");
  CloseHandle(GetStdHandle(STD_OUTPUT_HANDLE));
  const DWORD parent_wait = WaitForSingleObject(parent, 30000);
  CloseHandle(parent);
  if (parent_wait != WAIT_OBJECT_0) {
    ShowFailure(L"SuelosAR no se cerró. No se aplicó el paquete diferencial.");
    return 1;
  }
  if (!ValidateDifferential(paths, true)) {
    AppendDifferentialLog(paths, "post_shutdown_validation_failed");
    ShowFailure(L"El baseline cambió antes de aplicar la actualización. "
                L"Se requiere el Setup completo.");
    LaunchApplication(paths.app_path, paths.helper_directory, L"recovered",
                      paths.baseline_version, L"", nullptr);
    return 2;
  }
  if (HasAnotherAppProcess(paths.app_path, 0)) {
    AppendDifferentialLog(paths, "application_still_running_after_shutdown");
    ShowFailure(L"SuelosAR sigue abierto en otro proceso. No se aplicó el paquete diferencial.");
    LaunchApplication(paths.app_path, paths.helper_directory, L"recovered",
                      paths.baseline_version, L"", nullptr);
    return 2;
  }
  std::vector<wchar_t> helper_buffer(32768);
  const DWORD helper_length = GetModuleFileNameW(
      nullptr, helper_buffer.data(), static_cast<DWORD>(helper_buffer.size()));
  if (helper_length == 0 || helper_length >= helper_buffer.size()) return 2;
  const std::wstring helper_path(
      helper_buffer.data(), static_cast<size_t>(helper_length));
  DWORD worker_exit = 0;
  if (!RunElevatedDifferential(helper_path, args, L"--differential-worker",
                               &worker_exit)) {
    const DWORD error = GetLastError();
    if (error == ERROR_CANCELLED) {
      LaunchApplication(paths.app_path, paths.helper_directory, L"cancelled",
                        paths.baseline_version, L"", nullptr);
      return 2;
    }
    LaunchApplication(paths.app_path, paths.helper_directory, L"recovered",
                      paths.baseline_version, L"", nullptr);
    ShowFailure(L"No se pudo iniciar el proceso elevado para actualizar.");
    return 2;
  }
  if (worker_exit == 10) {
    LaunchApplication(paths.app_path, paths.helper_directory, L"recovered",
                      paths.baseline_version, L"", nullptr);
    ShowFailure(L"La actualización falló; se restauró el baseline anterior. "
                L"El Setup completo sigue disponible para recuperación.");
    return 10;
  }
  if (worker_exit != 0) {
    if (worker_exit != 11) {
      LaunchApplication(paths.app_path, paths.helper_directory, L"recovered",
                        paths.baseline_version, L"", nullptr);
    }
    ShowFailure(L"No se pudo aplicar o revertir el paquete diferencial. "
                L"Usá el Setup completo para recuperar la instalación.");
    return 11;
  }
  HANDLE restarted = nullptr;
  const auto confirmation = GenerateConfirmationToken();
  if (!LaunchApplication(paths.app_path, paths.helper_directory, L"installed",
                         paths.target_version, confirmation, &restarted)) {
    DWORD rollback_exit = 0;
    if (RunElevatedDifferential(helper_path, args, L"--differential-rollback",
                                &rollback_exit) && rollback_exit == 0) {
      LaunchApplication(paths.app_path, paths.helper_directory, L"recovered",
                        paths.baseline_version, L"", nullptr);
      ShowFailure(L"No se pudo iniciar la versión nueva. Se revirtió la "
                  L"actualización al baseline anterior.");
      return 10;
    }
    ShowFailure(L"No se pudo iniciar la versión nueva ni confirmar el rollback. "
                L"Se conserva el journal; ejecutá el Setup completo.");
    return 11;
  }
  const DWORD idle = WaitForInputIdle(restarted, 15000);
  DWORD restarted_exit = STILL_ACTIVE;
  const bool got_exit = GetExitCodeProcess(restarted, &restarted_exit) != 0;
  CloseHandle(restarted);
  if (idle != 0 || !got_exit || restarted_exit != STILL_ACTIVE ||
      !WriteSuccessConfirmation(confirmation, paths.target_version)) {
    DWORD rollback_exit = 0;
    if (RunElevatedDifferential(helper_path, args, L"--differential-rollback",
                                &rollback_exit) && rollback_exit == 0) {
      LaunchApplication(paths.app_path, paths.helper_directory, L"recovered",
                        paths.baseline_version, L"", nullptr);
      ShowFailure(L"La nueva aplicación no confirmó su inicio; se restauró "
                  L"la versión anterior.");
      return 10;
    }
    ShowFailure(L"No se confirmó el inicio y el rollback no pudo verificarse. "
                L"Se conserva la evidencia para recuperación manual.");
    return 11;
  }
  if (!DeleteRecoveryTask(paths, true)) {
    AppendDifferentialLog(paths, "recovery_task_cleanup_deferred_after_confirmation");
    return 0;
  }
  if (!DeleteUpdateDirectory(paths.update_directory)) {
    AppendDifferentialLog(paths, "post_commit_cleanup_failed");
  }
  return 0;
}

int Run(const std::vector<std::wstring>& args) {
  if (args.size() > 1 && args[1] == L"--differential") {
    return RunDifferentialBroker(args);
  }
  if (args.size() > 1 && args[1] == L"--differential-worker") {
    return RunDifferentialWorker(args, false);
  }
  if (args.size() > 1 && args[1] == L"--differential-rollback") {
    return RunDifferentialWorker(args, true);
  }
  if (args.size() > 1 && args[1] == L"--differential-recovery") {
    return RunDifferentialRecovery(args);
  }
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
