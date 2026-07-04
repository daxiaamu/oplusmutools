#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <propkey.h>
#include <setupapi.h>

#include <string>
#include <vector>

#define IDI_APPICON 101
#define IDR_PAYLOAD_CAB 201

#ifndef STARTF_TITLEISLINKNAME
#define STARTF_TITLEISLINKNAME 0x00000800
#endif

extern "C" HRESULT WINAPI SHGetPropertyStoreForWindow(HWND hwnd, REFIID riid, void** ppv);

static const wchar_t* kAppUserModelId = L"{{APP_ID}}";
static const wchar_t* kDisplayName = L"{{DISPLAY_NAME}}";
static const wchar_t* kPayloadName = L"{{PAYLOAD_NAME}}";
static const wchar_t* kMarkerArg = L"{{MARKER_ARG}}";
static const wchar_t* kCmdSwitch = L"{{CMD_SWITCH}}";
static const bool kKeepExtracted = {{KEEP_EXTRACTED}} != 0;

static const wchar_t* kPayloadDirs[] = {
{{PAYLOAD_DIRS}}
};

static std::wstring QuoteArg(const std::wstring& value) {
    std::wstring out = L"\"";
    for (wchar_t ch : value) {
        if (ch == L'"') out += L'\\';
        out += ch;
    }
    out += L"\"";
    return out;
}

static std::wstring QuoteCmdArg(const std::wstring& value) {
    std::wstring out = L"\"";
    for (wchar_t ch : value) {
        if (ch == L'"') out += L'"';
        out += ch;
    }
    out += L"\"";
    return out;
}

static std::wstring GetModulePath() {
    std::vector<wchar_t> buffer(MAX_PATH);
    DWORD len = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    while (len == buffer.size()) {
        buffer.resize(buffer.size() * 2);
        len = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    }
    return std::wstring(buffer.data(), len);
}

static bool FileExists(const std::wstring& path) {
    DWORD attr = GetFileAttributesW(path.c_str());
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

static bool EnsureDirectory(const std::wstring& dir) {
    if (dir.empty()) return false;
    if (CreateDirectoryW(dir.c_str(), nullptr)) return true;
    return GetLastError() == ERROR_ALREADY_EXISTS;
}

static std::wstring GetWorkDir() {
    std::vector<wchar_t> temp(MAX_PATH);
    DWORD len = GetTempPathW(static_cast<DWORD>(temp.size()), temp.data());
    if (len == 0 || len >= temp.size()) return L"";

    std::wstring root(temp.data(), len);
    root += L"BatConhost_";
    root += std::to_wstring(GetCurrentProcessId());
    EnsureDirectory(root);
    return root;
}

static bool EnsureParentDirectory(const std::wstring& path) {
    size_t slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return true;

    std::wstring dir = path.substr(0, slash);
    if (dir.empty()) return true;

    std::wstring current;
    for (size_t i = 0; i < dir.size(); ++i) {
        wchar_t ch = dir[i];
        current += ch;
        if (ch == L'\\' || ch == L'/') {
            if (current.size() > 3) EnsureDirectory(current);
        }
    }
    return EnsureDirectory(dir);
}

static int ShowError(const wchar_t* message, const std::wstring& detail = L"") {
    std::wstring text = message;
    if (!detail.empty()) {
        text += L"\n\n";
        text += detail;
    }
    MessageBoxW(nullptr, text.c_str(), kDisplayName, MB_ICONERROR | MB_OK);
    return 1;
}

static bool WriteResourceToFile(int resourceId, const wchar_t* resourceType, const std::wstring& targetPath) {
    if (!EnsureParentDirectory(targetPath)) return false;

    HMODULE module = GetModuleHandleW(nullptr);
    HRSRC resource = FindResourceW(module, MAKEINTRESOURCEW(resourceId), resourceType);
    if (!resource) return false;

    HGLOBAL loaded = LoadResource(module, resource);
    if (!loaded) return false;

    DWORD size = SizeofResource(module, resource);
    void* data = LockResource(loaded);
    if (!data || size == 0) return false;

    HANDLE file = CreateFileW(targetPath.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;

    DWORD written = 0;
    BOOL ok = WriteFile(file, data, size, &written, nullptr);
    CloseHandle(file);
    return ok && written == size;
}

struct ExtractContext {
    std::wstring targetDir;
};

static UINT CALLBACK CabinetCallback(PVOID context, UINT notification, UINT_PTR param1, UINT_PTR) {
    ExtractContext* extract = static_cast<ExtractContext*>(context);

    if (notification == SPFILENOTIFY_FILEINCABINET) {
        FILE_IN_CABINET_INFO_W* info = reinterpret_cast<FILE_IN_CABINET_INFO_W*>(param1);
        std::wstring relative(info->NameInCabinet);
        for (wchar_t& ch : relative) {
            if (ch == L'/') ch = L'\\';
        }

        if (relative.empty() || relative.find(L"..") != std::wstring::npos ||
            relative.find(L":") != std::wstring::npos ||
            relative[0] == L'\\' || relative[0] == L'/') {
            return FILEOP_ABORT;
        }

        std::wstring fullPath = extract->targetDir + L"\\" + relative;
        if (!EnsureParentDirectory(fullPath)) return FILEOP_ABORT;
        wcsncpy(info->FullTargetName, fullPath.c_str(), MAX_PATH - 1);
        info->FullTargetName[MAX_PATH - 1] = L'\0';
        return FILEOP_DOIT;
    }

    if (notification == SPFILENOTIFY_FILEEXTRACTED) return NO_ERROR;
    if (notification == SPFILENOTIFY_NEEDNEWCABINET) return ERROR_FILE_NOT_FOUND;
    return NO_ERROR;
}

static bool ExtractCabinet(const std::wstring& cabPath, const std::wstring& targetDir) {
    ExtractContext context{targetDir};
    return SetupIterateCabinetW(cabPath.c_str(), 0, CabinetCallback, &context) != FALSE;
}

static bool CreatePayloadDirectories(const std::wstring& workDir) {
    for (const wchar_t* relativeDir : kPayloadDirs) {
        if (!relativeDir || !relativeDir[0]) continue;
        std::wstring path = workDir + L"\\" + relativeDir;
        if (!EnsureParentDirectory(path)) return false;
        if (!EnsureDirectory(path)) return false;
    }
    return true;
}

static void DeleteTree(const std::wstring& path) {
    std::wstring search = path + L"\\*";
    WIN32_FIND_DATAW data{};
    HANDLE find = FindFirstFileW(search.c_str(), &data);
    if (find != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(data.cFileName, L".") == 0 || wcscmp(data.cFileName, L"..") == 0) continue;
            std::wstring child = path + L"\\" + data.cFileName;
            if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                DeleteTree(child);
            } else {
                SetFileAttributesW(child.c_str(), FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(child.c_str());
            }
        } while (FindNextFileW(find, &data));
        FindClose(find);
    }
    RemoveDirectoryW(path.c_str());
}

static bool CreateConsoleShortcut(const std::wstring& shortcutPath) {
    HRESULT coInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool shouldUninit = SUCCEEDED(coInit);

    IShellLinkW* link = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link));
    if (FAILED(hr) || !link) {
        if (shouldUninit) CoUninitialize();
        return false;
    }

    std::wstring modulePath = GetModulePath();
    link->SetPath(modulePath.c_str());
    link->SetIconLocation(modulePath.c_str(), 0);
    link->SetDescription(kDisplayName);

    IPropertyStore* store = nullptr;
    if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&store))) && store) {
        PROPVARIANT appId;
        PropVariantInit(&appId);
        appId.vt = VT_LPWSTR;
        appId.pwszVal = const_cast<LPWSTR>(kAppUserModelId);
        store->SetValue(PKEY_AppUserModel_ID, appId);
        store->Commit();
        store->Release();
    }

    IPersistFile* persist = nullptr;
    hr = link->QueryInterface(IID_PPV_ARGS(&persist));
    bool ok = false;
    if (SUCCEEDED(hr) && persist) {
        ok = SUCCEEDED(persist->Save(shortcutPath.c_str(), TRUE));
        persist->Release();
    }

    link->Release();
    if (shouldUninit) CoUninitialize();
    return ok;
}

static std::wstring GetCommandLineTail() {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return L"";

    std::wstring tail;
    for (int i = 1; i < argc; ++i) {
        if (!tail.empty()) tail += L" ";
        tail += QuoteCmdArg(argv[i]);
    }

    LocalFree(argv);
    return tail;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    std::wstring workDir = GetWorkDir();
    if (workDir.empty()) return ShowError(L"Cannot create temp work directory.");

    std::wstring batPath = workDir + L"\\" + kPayloadName;
    std::wstring cabPath = workDir + L"\\payload.cab";
    std::wstring shortcutPath = workDir + L"\\" + kDisplayName + L".lnk";

    if (!WriteResourceToFile(IDR_PAYLOAD_CAB, RT_RCDATA, cabPath) || !FileExists(cabPath)) {
        return ShowError(L"Cannot extract embedded cabinet.", cabPath);
    }
    if (!CreatePayloadDirectories(workDir)) {
        return ShowError(L"Cannot create embedded directories.", workDir);
    }
    if (!ExtractCabinet(cabPath, workDir) || !FileExists(batPath)) {
        return ShowError(L"Cannot unpack embedded files.", cabPath);
    }
    DeleteFileW(cabPath.c_str());

    CreateConsoleShortcut(shortcutPath);

    wchar_t systemDir[MAX_PATH] = {};
    UINT systemLen = GetSystemDirectoryW(systemDir, MAX_PATH);
    if (systemLen == 0 || systemLen >= MAX_PATH) return ShowError(L"Cannot locate Windows system directory.");

    std::wstring conhost = std::wstring(systemDir) + L"\\conhost.exe";
    std::wstring cmd = std::wstring(systemDir) + L"\\cmd.exe";
    if (!FileExists(cmd)) return ShowError(L"Cannot find cmd.exe.", cmd);

    std::wstring tail = GetCommandLineTail();
    std::wstring batCommand = QuoteCmdArg(batPath);
    if (kMarkerArg[0] != L'\0') batCommand += L" " + QuoteCmdArg(kMarkerArg);
    if (!tail.empty()) batCommand += L" " + tail;

    std::wstring application;
    std::wstring commandLine;
    DWORD creationFlags = 0;
    if (FileExists(conhost)) {
        application = conhost;
        commandLine = QuoteArg(conhost) + L" " + QuoteArg(cmd) + L" /d /s " + kCmdSwitch + L" \"" + batCommand + L"\"";
    } else {
        application = cmd;
        commandLine = QuoteArg(cmd) + L" /d /s " + kCmdSwitch + L" \"" + batCommand + L"\"";
        creationFlags = CREATE_NEW_CONSOLE;
    }

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    if (FileExists(shortcutPath)) {
        si.dwFlags |= STARTF_TITLEISLINKNAME;
        si.lpTitle = const_cast<LPWSTR>(shortcutPath.c_str());
    }

    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
    mutableCommand.push_back(L'\0');

    BOOL ok = CreateProcessW(application.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
        creationFlags, nullptr, workDir.c_str(), &si, &pi);
    if (!ok) return ShowError(L"Cannot launch console.", commandLine);

    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    if (!kKeepExtracted) DeleteTree(workDir);
    return 0;
}
