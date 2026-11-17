# Bind Google's signed "Android Bootloader Interface" driver to the OnePlus 6 in fastboot mode
# (USB\VID_18D1&PID_D00D), the same steps as Device Manager > Update driver > Have Disk > Android Bootloader Interface.
# Windows has no driver for the phone's fastboot mode, so fastboot.exe cannot see it without this.
# Usage: download the Google USB Driver (https://developer.android.com/studio/run/win-usb), extract it so that
# usb_driver\android_winusb.inf sits next to this script, put the phone in fastboot, then run in an elevated
# PowerShell:  powershell -ExecutionPolicy Bypass -File install-fastboot-driver.ps1
# Windows asks once whether to trust the publisher (Google) - answer Install. Writes a log next to itself.
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'install-fastboot-driver.log'
Start-Transcript -Path $log -Force | Out-Null
try {
  $inf = Join-Path $PSScriptRoot 'usb_driver\android_winusb.inf'
  $dev = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_18D1&PID_D00D\*' } | Select-Object -First 1
  if (-not $dev) { throw 'phone not found in fastboot mode (USB\VID_18D1&PID_D00D)' }
  "device: $($dev.InstanceId) status=$($dev.Status)"
  pnputil /add-driver "$inf"
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DrvBind {
  [StructLayout(LayoutKind.Sequential)] public struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SP_DEVINSTALL_PARAMS {
    public int cbSize; public int Flags; public int FlagsEx; public IntPtr hwndParent; public IntPtr InstallMsgHandler; public IntPtr InstallMsgHandlerContext; public IntPtr FileQueue; public IntPtr ClassInstallReserved; public int Reserved;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string DriverPath; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode, Pack=4)] public struct SP_DRVINFO_DATA {
    public int cbSize; public int DriverType; public IntPtr Reserved;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Description;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string MfgName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string ProviderName;
    public long DriverDate; public long DriverVersion; }
  [DllImport("setupapi.dll", SetLastError=true)] public static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr g, IntPtr hwnd);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiOpenDeviceInfo(IntPtr set, string id, IntPtr hwnd, int flags, ref SP_DEVINFO_DATA d);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiGetDeviceInstallParams(IntPtr set, ref SP_DEVINFO_DATA d, ref SP_DEVINSTALL_PARAMS p);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiSetDeviceInstallParams(IntPtr set, ref SP_DEVINFO_DATA d, ref SP_DEVINSTALL_PARAMS p);
  [DllImport("setupapi.dll", SetLastError=true)] public static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA d, int prop, byte[] buf, int size);
  [DllImport("setupapi.dll", SetLastError=true)] public static extern bool SetupDiBuildDriverInfoList(IntPtr set, ref SP_DEVINFO_DATA d, int type);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiEnumDriverInfo(IntPtr set, ref SP_DEVINFO_DATA d, int type, int idx, ref SP_DRVINFO_DATA di);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiSetSelectedDriver(IntPtr set, ref SP_DEVINFO_DATA d, ref SP_DRVINFO_DATA di);
  [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool DiInstallDevice(IntPtr hwnd, IntPtr set, ref SP_DEVINFO_DATA d, ref SP_DRVINFO_DATA di, int flags, out bool reboot);
  public static string Bind(string instanceId, string inf, string model) {
    Guid cls = new Guid("3F966BD9-FA04-4ec5-991C-D326973B5128"); // AndroidUsbDeviceClass from android_winusb.inf
    IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
    SP_DEVINFO_DATA d = new SP_DEVINFO_DATA(); d.cbSize = Marshal.SizeOf(d);
    if (!SetupDiOpenDeviceInfo(set, instanceId, IntPtr.Zero, 0, ref d)) return "open failed " + Marshal.GetLastWin32Error();
    byte[] g = System.Text.Encoding.Unicode.GetBytes("{3F966BD9-FA04-4ec5-991C-D326973B5128}\0");
    SetupDiSetDeviceRegistryProperty(set, ref d, 8 /*SPDRP_CLASSGUID*/, g, g.Length);
    d.ClassGuid = cls;
    SP_DEVINSTALL_PARAMS p = new SP_DEVINSTALL_PARAMS(); p.cbSize = Marshal.SizeOf(p);
    if (!SetupDiGetDeviceInstallParams(set, ref d, ref p)) return "getparams failed " + Marshal.GetLastWin32Error();
    p.Flags |= 0x00010000;      // DI_ENUMSINGLEINF
    p.FlagsEx |= 0x00000800;    // DI_FLAGSEX_ALLOWEXCLUDEDDRVS
    p.DriverPath = inf;
    if (!SetupDiSetDeviceInstallParams(set, ref d, ref p)) return "setparams failed " + Marshal.GetLastWin32Error();
    if (!SetupDiBuildDriverInfoList(set, ref d, 1 /*SPDIT_CLASSDRIVER*/)) return "build list failed " + Marshal.GetLastWin32Error();
    SP_DRVINFO_DATA di = new SP_DRVINFO_DATA(); di.cbSize = Marshal.SizeOf(di);
    string seen = "";
    for (int i = 0; SetupDiEnumDriverInfo(set, ref d, 1, i, ref di); i++) {
      seen += di.Description + "; ";
      if (di.Description == model) {
        if (!SetupDiSetSelectedDriver(set, ref d, ref di)) return "select failed " + Marshal.GetLastWin32Error();
        bool reboot;
        if (!DiInstallDevice(IntPtr.Zero, set, ref d, ref di, 0, out reboot)) return "install failed " + Marshal.GetLastWin32Error();
        return "installed '" + model + "' reboot=" + reboot;
      }
      di = new SP_DRVINFO_DATA(); di.cbSize = Marshal.SizeOf(di);
    }
    return "model not found; models: " + seen;
  }
}
'@
  [DrvBind]::Bind($dev.InstanceId, $inf, 'Android Bootloader Interface')
  Get-PnpDevice -InstanceId $dev.InstanceId | Format-List Status, Class, FriendlyName
} catch { "ERROR: $_" }
Stop-Transcript | Out-Null
