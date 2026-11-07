; ============================================================
; SuelosAR - Windows Installer
; Inno Setup
; ============================================================

#define MyAppName "SuelosAR"
#define MyAppVersion GetEnv("SUELOSAR_VERSION")
#define VCRuntimeRequiredVersion "14.51.36231.0"
#if MyAppVersion == ""
  #error "Compile using tool/build_windows_installer.ps1 so the version comes from pubspec.yaml."
#endif
#define MyAppVersionInfo MyAppVersion + ".0"

#define MyAppPublisher "SuelosAR"
#define MyAppURL "https://web-suelos-ar.vercel.app/"
#define MyAppExeName "suelosar.exe"

; Paths are resolved from this script's checkout directory.
#define ProjectDir RemoveBackslashUnlessRoot(SourcePath)
#define BuildDir GetEnv("SUELOSAR_BUILD_DIR")
#if BuildDir == ""
  #define BuildDir ProjectDir + "\build\windows\x64\runner\Release"
#endif

; Installer resources and output remain inside the checkout.
#define InstallerResourcesDir ProjectDir + "\windows\runner\resources"
#define InstallerOutputDir ProjectDir + "\artifacts\windows-installer"
#define VCRedistPath ProjectDir + "\tool\prerequisites\vc_redist.x64.exe"

#if !DirExists(BuildDir)
  #error "Flutter Windows Release directory is missing. Build the Windows Release app first."
#endif
#if !FileExists(BuildDir + "\suelosar.exe")
  #error "Flutter Windows Release executable is missing: suelosar.exe."
#endif
#if !FileExists(BuildDir + "\suelosar_update_helper.exe")
  #error "Flutter Windows Release installer helper is missing: suelosar_update_helper.exe."
#endif
#if !FileExists(InstallerResourcesDir + "\app_icon.ico")
  #error "Installer icon is missing: windows\runner\resources\app_icon.ico."
#endif
#if !FileExists(VCRedistPath)
  #error "The Microsoft Visual C++ x64 Redistributable prerequisite is missing."
#endif

[Setup]

; IMPORTANT: Never change this GUID in future releases.
AppId={{C7098677-ADDE-4FE4-A0FA-E24AC63B3CD0}

AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}

AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}

DefaultDirName={autopf}\{#MyAppName}

SetupIconFile={#InstallerResourcesDir}\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

OutputDir={#InstallerOutputDir}
OutputBaseFilename=SuelosAR-Setup-{#MyAppVersion}

VersionInfoVersion={#MyAppVersionInfo}
VersionInfoProductVersion={#MyAppVersionInfo}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=SuelosAR Setup
VersionInfoProductName={#MyAppName}
VersionInfoTextVersion={#MyAppVersion}
VersionInfoProductTextVersion={#MyAppVersion}

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

DisableProgramGroupPage=yes

SolidCompression=yes
WizardStyle=modern dark

; Automatically detect the Windows language.
; Spanish is the fallback language.
ShowLanguageDialog=no

; Application closing during installation
CloseApplications=yes

[Languages]

Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]

Name: "desktopicon"; \
    Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; \
    Flags: unchecked

[Files]

Source: "{#BuildDir}\*"; \
    DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

Source: "{#VCRedistPath}"; Flags: dontcopy

[Icons]

Name: "{autoprograms}\{#MyAppName}"; \
    Filename: "{app}\{#MyAppExeName}"

Name: "{autodesktop}\{#MyAppName}"; \
    Filename: "{app}\{#MyAppExeName}"; \
    Tasks: desktopicon

[Run]

Filename: "{app}\{#MyAppExeName}"; \
    Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; \
    Check: not IsUpdaterDrivenInstall and not VCRuntimeRestartRequired; \
    Flags: nowait postinstall skipifsilent

[Code]
const
  VCRuntimeRegistryKey = 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';
var
  VCRuntimeNeedsRestart: Boolean;

function VCRuntimeRestartRequired: Boolean;
begin
  Result := VCRuntimeNeedsRestart;
end;

function IsUpdaterDrivenInstall: Boolean;
var
  I: Integer;
  Value: String;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    Value := Lowercase(ParamStr(I));
    if (Pos('/log=', Value) = 1) and
       (Pos('suelosar-update-', Value) > 0) and
       (Pos('\setup.log', Value) > 0) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function UpdaterRestartMarkerPath: String;
var
  I: Integer;
  Value, LogPath: String;
begin
  Result := '';
  if not IsUpdaterDrivenInstall then Exit;
  for I := 1 to ParamCount do
  begin
    Value := ParamStr(I);
    if Pos('/log=', Lowercase(Value)) = 1 then
    begin
      LogPath := Copy(Value, 6, Length(Value));
      Result := ExtractFilePath(LogPath) + 'vcruntime-restart-required.flag';
      Exit;
    end;
  end;
end;

function ReadVersionPart(var VersionText: String; var Number: Integer): Boolean;
var
  DotPosition, ParsedNumber: Integer;
  Part: String;
begin
  DotPosition := Pos('.', VersionText);
  if DotPosition = 0 then
  begin
    Part := VersionText;
    VersionText := '';
  end
  else
  begin
    Part := Copy(VersionText, 1, DotPosition - 1);
    Delete(VersionText, 1, DotPosition);
  end;
  ParsedNumber := StrToIntDef(Part, -1);
  Result := ParsedNumber >= 0;
  if Result then Number := ParsedNumber;
end;

function VersionAtLeast(InstalledVersion, RequiredVersion: String): Boolean;
var
  I, InstalledPart, RequiredPart: Integer;
begin
  if (Copy(InstalledVersion, 1, 1) = 'v') or
     (Copy(InstalledVersion, 1, 1) = 'V') then
    Delete(InstalledVersion, 1, 1);
  for I := 1 to 3 do
  begin
    if not ReadVersionPart(InstalledVersion, InstalledPart) or
       not ReadVersionPart(RequiredVersion, RequiredPart) then
    begin
      Result := False;
      Exit;
    end;
    if InstalledPart > RequiredPart then
    begin
      Result := True;
      Exit;
    end;
    if InstalledPart < RequiredPart then
    begin
      Result := False;
      Exit;
    end;
  end;
  Result := True;
end;

function IsVCRuntimeInstalled: Boolean;
var
  Installed: Cardinal;
  InstalledVersion: String;
begin
  Result := RegQueryDWordValue(
    HKLM64, VCRuntimeRegistryKey, 'Installed', Installed) and
    (Installed = 1) and
    RegQueryStringValue(
      HKLM64, VCRuntimeRegistryKey, 'Version', InstalledVersion) and
    VersionAtLeast(InstalledVersion, '{#VCRuntimeRequiredVersion}');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  Parameters: String;
begin
  Result := '';
  NeedsRestart := False;
  VCRuntimeNeedsRestart := False;
  if IsVCRuntimeInstalled then Exit;

  ExtractTemporaryFile('vc_redist.x64.exe');
  if WizardSilent then
    Parameters := '/install /quiet /norestart'
  else
    Parameters := '/install /passive /norestart';

  if not Exec(
    ExpandConstant('{tmp}\vc_redist.x64.exe'),
    Parameters, '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
  begin
    Result := 'No se pudo iniciar el requisito Microsoft Visual C++ Runtime.';
    Exit;
  end;

  if ResultCode = 1602 then
  begin
    Result := 'Se canceló la instalación del requisito Visual C++ Runtime.';
    Exit;
  end;
  if (ResultCode = 3010) or (ResultCode = 1641) then
  begin
    NeedsRestart := True;
    VCRuntimeNeedsRestart := True;
  end
  else if ResultCode <> 0 then
  begin
    Result := 'Falló la instalación de Visual C++ Runtime (código ' +
      IntToStr(ResultCode) + ').';
    Exit;
  end;

  if not IsVCRuntimeInstalled then
  begin
    if NeedsRestart then
      Result := 'Visual C++ Runtime requiere reiniciar Windows antes de ' +
        'poder verificarse. Reinicie y vuelva a ejecutar el instalador.'
    else
      Result := 'El instalador de Visual C++ Runtime terminó, pero no se ' +
        'detectó la versión mínima requerida.';
  end;

  if NeedsRestart and IsUpdaterDrivenInstall then
  begin
    if (UpdaterRestartMarkerPath = '') or
       not SaveStringToFile(
         UpdaterRestartMarkerPath,
         'Visual C++ Runtime requires a Windows restart.', False) then
      Result := 'No se pudo registrar el reinicio requerido por Visual C++ Runtime.';
  end;
end;
