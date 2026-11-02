; ============================================================
; SuelosAR - Windows Installer
; Inno Setup
; ============================================================

#define MyAppName "SuelosAR"
#define MyAppVersion GetEnv("SUELOSAR_VERSION")
#if MyAppVersion == ""
  #error "Compile using tool/build_windows_installer.ps1 so the version comes from pubspec.yaml."
#endif
#define MyAppVersionInfo MyAppVersion + ".0"

#define MyAppPublisher "SuelosAR"
#define MyAppURL "https://web-suelos-ar.vercel.app/"
#define MyAppExeName "suelosar.exe"

; Paths are resolved from this script's checkout directory.
#define ProjectDir RemoveBackslashUnlessRoot(SourcePath)
#define BuildDir ProjectDir + "\build\windows\x64\runner\Release"

; Installer resources and output remain inside the checkout.
#define InstallerResourcesDir ProjectDir + "\windows\runner\resources"
#define InstallerOutputDir ProjectDir + "\artifacts\windows-installer"

#if !DirExists(BuildDir)
  #error "Flutter Windows Release directory is missing. Build the Windows Release app first."
#endif
#if !FileExists(BuildDir + "\suelosar.exe")
  #error "Flutter Windows Release executable is missing: suelosar.exe."
#endif
#if !FileExists(InstallerResourcesDir + "\app_icon.ico")
  #error "Installer icon is missing: windows\runner\resources\app_icon.ico."
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

[Icons]

Name: "{autoprograms}\{#MyAppName}"; \
    Filename: "{app}\{#MyAppExeName}"

Name: "{autodesktop}\{#MyAppName}"; \
    Filename: "{app}\{#MyAppExeName}"; \
    Tasks: desktopicon

[Run]

Filename: "{app}\{#MyAppExeName}"; \
    Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; \
    Flags: nowait postinstall skipifsilent
