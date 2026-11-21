// GraphClip.exe: starts the GraphClip PowerShell scripts with PowerShell 7 without showing a console window.
// Built by Build-GraphClipMsi.ps1 with the .NET Framework C# compiler, so it must stay C# 5 compatible.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace GraphClip
{
    internal static class Launcher
    {
        private const string Title = "GraphClip";
        private const string Usage =
            "Usage:\n" +
            "  GraphClip.exe            Start the clipboard watcher in the notification area.\n" +
            "  GraphClip.exe --convert  Convert the Microsoft Graph request in the clipboard now.";

        [STAThread]
        private static int Main(string[] args)
        {
            string script;
            bool waitForExit;
            if (args.Length == 0)
            {
                script = "GraphClip-Watcher.ps1";
                waitForExit = false;
            }
            else if (args.Length == 1 && IsOption(args[0], "convert"))
            {
                script = "Invoke-GraphClip.ps1";
                waitForExit = true;
            }
            else
            {
                bool help = args.Length == 1 && (IsOption(args[0], "help") || args[0] == "/?" || args[0] == "-?");
                MessageBox.Show(Usage, Title, MessageBoxButtons.OK, help ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
                return help ? 0 : 87;
            }

            string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(baseDirectory, script);
            if (!File.Exists(scriptPath))
            {
                ShowError("GraphClip is incomplete because " + scriptPath + " was not found. Repair or reinstall GraphClip.");
                return 2;
            }

            string pwsh = FindPwsh();
            if (pwsh == null)
            {
                ShowError("GraphClip requires PowerShell 7 or later.\n\nInstall it with:\n  winget install --id Microsoft.PowerShell");
                return 3;
            }

            ProcessStartInfo startInfo = new ProcessStartInfo(
                pwsh,
                "-NoProfile -STA -ExecutionPolicy RemoteSigned -File \"" + scriptPath + "\"");
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WorkingDirectory = baseDirectory;
            try
            {
                using (Process process = Process.Start(startInfo))
                {
                    if (!waitForExit)
                    {
                        return 0;
                    }
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception ex)
            {
                ShowError("Could not start PowerShell 7 from " + pwsh + ".\n\n" + ex.Message);
                return 4;
            }
        }

        private static bool IsOption(string argument, string name)
        {
            return string.Equals(argument, "--" + name, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(argument, "-" + name, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(argument, "/" + name, StringComparison.OrdinalIgnoreCase);
        }

        // PowerShell 7 can be a machine-wide MSI install or a per-user MSIX/Store install, which WinGet's
        // Microsoft.PowerShell package now uses. The MSIX version is reached through its App Execution Alias.
        private static string FindPwsh()
        {
            List<string> candidates = new List<string>();
            candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe"));
            string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            foreach (string entry in path.Split(';'))
            {
                string directory = Environment.ExpandEnvironmentVariables(entry.Trim().Trim('"'));
                if (directory.Length == 0 || directory.IndexOfAny(Path.GetInvalidPathChars()) >= 0 || !Path.IsPathRooted(directory))
                {
                    continue;
                }
                candidates.Add(Path.Combine(directory, "pwsh.exe"));
            }
            candidates.Add(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\pwsh.exe"));

            foreach (string candidate in candidates)
            {
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            return null;
        }

        private static void ShowError(string message)
        {
            MessageBox.Show(message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
