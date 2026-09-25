<#
.SYNOPSIS
    Atomic Windows Credential Manager Helper for Google Antigravity
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("read", "write")]
    [string]$Action,

    [Parameter(Mandatory=$true)]
    [string]$Target,

    [Parameter(Mandatory=$false)]
    [string]$UserName = "antigravity",

    [Parameter(Mandatory=$false)]
    [string]$SecretFile
)

$code = @'
using System;
using System.Runtime.InteropServices;

public class WinCredHelper {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredWrite([In] ref CREDENTIAL userCredential, [In] uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
    public static extern void CredFree([In] IntPtr cred);

    public static string Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) return null;
        try {
            var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            byte[] bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
            return System.Text.Encoding.UTF8.GetString(bytes);
        } finally {
            CredFree(ptr);
        }
    }

    public static bool Write(string target, string userName, string secret) {
        byte[] bytes = System.Text.Encoding.UTF8.GetBytes(secret);
        IntPtr blobPtr = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, blobPtr, bytes.Length);
        try {
            var cred = new CREDENTIAL {
                Type = 1,
                TargetName = target,
                UserName = userName,
                CredentialBlobSize = bytes.Length,
                CredentialBlob = blobPtr,
                Persist = 2
            };
            return CredWrite(ref cred, 0);
        } finally {
            Marshal.FreeHGlobal(blobPtr);
        }
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'WinCredHelper').Type) {
    Add-Type -TypeDefinition $code -Language CSharp
}

if ($Action -eq "read") {
    $result = [WinCredHelper]::Read($Target)
    if ($null -ne $result) {
        [Console]::Out.Write($result)
    }
} elseif ($Action -eq "write") {
    if (-not (Test-Path $SecretFile)) {
        Write-Error "Secret file not found: $SecretFile"
        exit 1
    }
    $secret = [System.IO.File]::ReadAllText($SecretFile, [System.Text.Encoding]::UTF8)
    $ok = [WinCredHelper]::Write($Target, $UserName, $secret)
    if ($ok) {
        [Console]::Out.Write("SUCCESS")
    } else {
        Write-Error "CredWrite failed"
        exit 1
    }
}
