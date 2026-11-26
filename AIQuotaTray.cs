// AIQuotaTray.exe - AIQuotaTray.ps1 을 PowerShell 엔진(System.Management.Automation)으로 직접 실행하는 작은 실행기.
// powershell.exe 프로세스가 아니므로 PowerShell 창을 닫거나 "Windows PowerShell"을 종료해도 영향이 없다.
using System;
using System.IO;
using System.Threading;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "AIQuotaTray.ps1");
        string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ai-quota-tray");
        try
        {
            var iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (var rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (var ps = System.Management.Automation.PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    ps.Invoke();
                    if (ps.HadErrors)
                    {
                        Directory.CreateDirectory(logDir);
                        foreach (var e in ps.Streams.Error)
                            File.AppendAllText(Path.Combine(logDir, "error.log"), DateTime.Now.ToString("s") + " [launcher] " + e + Environment.NewLine);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            try
            {
                Directory.CreateDirectory(logDir);
                File.AppendAllText(Path.Combine(logDir, "error.log"), DateTime.Now.ToString("s") + " [launcher] " + ex + Environment.NewLine);
            }
            catch { }
            return 1;
        }
        return 0;
    }
}
