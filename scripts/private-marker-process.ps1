Set-StrictMode -Version Latest

if ($null -eq ('PrivateMarker.ProcessBoundary' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace PrivateMarker
{
    public sealed class BoundedReadResult
    {
        public byte[] Data { get; set; }
        public bool LimitExceeded { get; set; }
    }

    public static class BoundedStreamReader
    {
        public static async Task<BoundedReadResult> ReadAsync(Stream stream, int maximumBytes)
        {
            using (var output = new MemoryStream())
            {
                var buffer = new byte[8192];
                while (true)
                {
                    var read = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    if (read == 0)
                    {
                        return new BoundedReadResult {
                            Data = output.ToArray(),
                            LimitExceeded = false
                        };
                    }

                    if (output.Length + read > maximumBytes)
                    {
                        return new BoundedReadResult {
                            Data = output.ToArray(),
                            LimitExceeded = true
                        };
                    }
                    output.Write(buffer, 0, read);
                }
            }
        }
    }

    public static class ProcessBoundary
    {
        private const uint JobObjectExtendedLimitInformation = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            uint informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static IntPtr CreateKillOnCloseJob()
        {
            var job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            var limits = new ExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            var length = Marshal.SizeOf(typeof(ExtendedLimitInformation));
            var pointer = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(limits, pointer, false);
                if (!SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    pointer,
                    (uint)length))
                {
                    var error = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    throw new Win32Exception(error);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }
            return job;
        }

        public static void Assign(IntPtr job, IntPtr process)
        {
            if (!AssignProcessToJobObject(job, process))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        public static void Close(IntPtr job)
        {
            if (job != IntPtr.Zero && !CloseHandle(job))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        public static void Terminate(IntPtr job)
        {
            if (job != IntPtr.Zero && !TerminateJobObject(job, 1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }

    public sealed class ContainedProcess : IDisposable
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint ResumeFailed = 0xFFFFFFFF;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitFailed = 0xFFFFFFFF;
        private static readonly IntPtr ProcThreadAttributeHandleList =
            new IntPtr(0x00020002);

        private IntPtr jobHandle;
        private IntPtr processHandle;
        private bool disposed;
        private int syntheticJobCloseFailuresRemaining;

        public Stream StandardInput { get; private set; }
        public Stream StandardOutput { get; private set; }
        public Stream StandardError { get; private set; }
        public bool TargetReleased { get; private set; }
        public static int LastSyntheticFailureProcessId { get; private set; }

        private ContainedProcess(
            IntPtr childProcess,
            Stream standardInput,
            Stream standardOutput,
            Stream standardError,
            IntPtr job,
            bool targetReleased,
            int syntheticJobCloseFailures)
        {
            processHandle = childProcess;
            StandardInput = standardInput;
            StandardOutput = standardOutput;
            StandardError = standardError;
            TargetReleased = targetReleased;
            jobHandle = job;
            syntheticJobCloseFailuresRemaining =
                syntheticJobCloseFailures;
        }

        ~ContainedProcess()
        {
            // Disposeの全retryでもJob handleを閉じられなかった場合に、
            // process tree containmentとnative handleの最終回収を再試行する。
            if (jobHandle != IntPtr.Zero)
            {
                var handle = jobHandle;
                try
                {
                    ProcessBoundary.Terminate(handle);
                }
                catch
                {
                }
                try
                {
                    ProcessBoundary.Close(handle);
                    jobHandle = IntPtr.Zero;
                }
                catch
                {
                }
            }
            try
            {
                CloseOwnedHandle(ref processHandle);
            }
            catch
            {
                // finalizer threadへ例外を逃がさない。通常のDispose経路では
                // ownershipを保持したまま呼出元へcleanup failureを返す。
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public int X;
            public int Y;
            public int XSize;
            public int YSize;
            public int XCountChars;
            public int YCountChars;
            public int FillAttribute;
            public uint Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public int ProcessId;
            public int ThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(
            out IntPtr readPipe,
            out IntPtr writePipe,
            ref SecurityAttributes pipeAttributes,
            int size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(
            IntPtr handle,
            uint mask,
            uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(
            IntPtr attributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(
            IntPtr handle,
            uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(
            IntPtr process,
            out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        private static string Quote(string value)
        {
            if (String.IsNullOrEmpty(value))
            {
                return "\"\"";
            }
            if (value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
            {
                return value;
            }

            var result = new StringBuilder("\"");
            var backslashes = 0;
            foreach (var character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', (backslashes * 2) + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(character);
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static StringBuilder BuildCommandLine(
            string filePath,
            string[] arguments)
        {
            var commandLine = new StringBuilder(Quote(filePath));
            foreach (var argument in arguments)
            {
                commandLine.Append(' ');
                commandLine.Append(Quote(argument ?? String.Empty));
            }
            return commandLine;
        }

        private static IntPtr BuildEnvironmentBlock(IDictionary environment)
        {
            var entries = new List<string>();
            foreach (DictionaryEntry entry in environment)
            {
                var name = Convert.ToString(entry.Key);
                var value = Convert.ToString(entry.Value) ?? String.Empty;
                if (String.IsNullOrEmpty(name) ||
                    name.IndexOf('=') >= 0 ||
                    name.IndexOf('\0') >= 0 ||
                    value.IndexOf('\0') >= 0)
                {
                    throw new ArgumentException("Invalid child environment entry.");
                }
                entries.Add(name + "=" + value);
            }
            entries.Sort(StringComparer.OrdinalIgnoreCase);
            var block = String.Join("\0", entries.ToArray()) + "\0\0";
            return Marshal.StringToHGlobalUni(block);
        }

        private static Exception MergeCleanupFailure(
            Exception existingFailure,
            Exception nextFailure)
        {
            return existingFailure == null
                ? nextFailure
                : (Exception)new AggregateException(
                    existingFailure,
                    nextFailure);
        }

        private static void CaptureCleanupFailure(
            Action cleanup,
            ref Exception cleanupFailure)
        {
            try
            {
                cleanup();
            }
            catch (Exception failure)
            {
                cleanupFailure = MergeCleanupFailure(
                    cleanupFailure,
                    failure);
            }
        }

        private static void CloseOwnedHandle(ref IntPtr handle)
        {
            if (handle != IntPtr.Zero)
            {
                if (!CloseHandle(handle))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Closing an owned native handle failed.");
                }
                // close成功後だけownershipを手放す。失敗時はref値を保持し、
                // Dispose/finalizerまたはlaunch cleanupの次段で再試行する。
                handle = IntPtr.Zero;
            }
        }

        private static void CaptureOwnedHandleClose(
            ref IntPtr handle,
            ref Exception cleanupFailure)
        {
            try
            {
                CloseOwnedHandle(ref handle);
            }
            catch (Exception failure)
            {
                cleanupFailure = MergeCleanupFailure(
                    cleanupFailure,
                    failure);
            }
        }

        public static ContainedProcess Start(
            string filePath,
            string[] arguments,
            IDictionary environment,
            string workingDirectory,
            string testFailureMode,
            Stopwatch deadlineClock,
            long deadlineMilliseconds)
        {
            if (deadlineClock == null)
            {
                throw new ArgumentNullException("deadlineClock");
            }
            if (!String.IsNullOrEmpty(testFailureMode))
            {
                LastSyntheticFailureProcessId = 0;
            }
            IntPtr stdinRead = IntPtr.Zero;
            IntPtr stdinWrite = IntPtr.Zero;
            IntPtr stdoutRead = IntPtr.Zero;
            IntPtr stdoutWrite = IntPtr.Zero;
            IntPtr stderrRead = IntPtr.Zero;
            IntPtr stderrWrite = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr inheritedHandleList = IntPtr.Zero;
            IntPtr job = IntPtr.Zero;
            var processInformation = new ProcessInformation();
            FileStream stdin = null;
            FileStream stdout = null;
            FileStream stderr = null;
            var processCreated = false;
            var processAssigned = false;
            var attributeListInitialized = false;
            Exception primaryFailure = null;
            try
            {
                var attributes = new SecurityAttributes {
                    Length = Marshal.SizeOf(typeof(SecurityAttributes)),
                    InheritHandle = true
                };
                if (!CreatePipe(out stdinRead, out stdinWrite, ref attributes, 0) ||
                    !CreatePipe(out stdoutRead, out stdoutWrite, ref attributes, 0) ||
                    !CreatePipe(out stderrRead, out stderrWrite, ref attributes, 0))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreatePipe failed.");
                }
                if (!SetHandleInformation(stdinWrite, HandleFlagInherit, 0) ||
                    !SetHandleInformation(stdoutRead, HandleFlagInherit, 0) ||
                    !SetHandleInformation(stderrRead, HandleFlagInherit, 0))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetHandleInformation failed.");
                }

                var attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    1,
                    0,
                    ref attributeListSize);
                if (attributeListSize == IntPtr.Zero)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "InitializeProcThreadAttributeList size query failed.");
                }
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(
                    attributeList,
                    1,
                    0,
                    ref attributeListSize))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "InitializeProcThreadAttributeList failed.");
                }
                attributeListInitialized = true;

                inheritedHandleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(inheritedHandleList, 0, stdinRead);
                Marshal.WriteIntPtr(inheritedHandleList, IntPtr.Size, stdoutWrite);
                Marshal.WriteIntPtr(
                    inheritedHandleList,
                    IntPtr.Size * 2,
                    stderrWrite);
                if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    ProcThreadAttributeHandleList,
                    inheritedHandleList,
                    new IntPtr(IntPtr.Size * 3),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "UpdateProcThreadAttribute failed.");
                }

                var startupInfo = new StartupInfoEx();
                startupInfo.StartupInfo.Size =
                    Marshal.SizeOf(typeof(StartupInfoEx));
                startupInfo.StartupInfo.Flags = StartfUseStdHandles;
                startupInfo.StartupInfo.StandardInput = stdinRead;
                startupInfo.StartupInfo.StandardOutput = stdoutWrite;
                startupInfo.StartupInfo.StandardError = stderrWrite;
                startupInfo.AttributeList = attributeList;

                job = ProcessBoundary.CreateKillOnCloseJob();
                environmentBlock = BuildEnvironmentBlock(environment);
                if (!CreateProcessW(
                    filePath,
                    BuildCommandLine(filePath, arguments),
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateSuspended |
                        CreateUnicodeEnvironment |
                        CreateNoWindow |
                        ExtendedStartupInfoPresent,
                    environmentBlock,
                    String.IsNullOrWhiteSpace(workingDirectory)
                        ? null
                        : workingDirectory,
                    ref startupInfo,
                    out processInformation))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreateProcessW failed.");
                }
                processCreated = true;
                if (!String.IsNullOrEmpty(testFailureMode))
                {
                    LastSyntheticFailureProcessId =
                        processInformation.ProcessId;
                }

                // Job割当前のfailureでもtargetはsuspendedのまま。catchの
                // terminate + bounded waitが完了するまで呼出元へ戻さない。
                if (String.Equals(
                    testFailureMode,
                    "assign",
                    StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "Synthetic Job assignment failure.");
                }

                ProcessBoundary.Assign(job, processInformation.Process);
                processAssigned = true;

                var stdinHandle = new SafeFileHandle(stdinWrite, true);
                stdinWrite = IntPtr.Zero;
                var stdoutHandle = new SafeFileHandle(stdoutRead, true);
                stdoutRead = IntPtr.Zero;
                var stderrHandle = new SafeFileHandle(stderrRead, true);
                stderrRead = IntPtr.Zero;
                stdin = new FileStream(
                    stdinHandle,
                    FileAccess.Write,
                    8192,
                    false);
                stdout = new FileStream(
                    stdoutHandle,
                    FileAccess.Read,
                    8192,
                    false);
                stderr = new FileStream(
                    stderrHandle,
                    FileAccess.Read,
                    8192,
                    false);

                CloseOwnedHandle(ref stdinRead);
                CloseOwnedHandle(ref stdoutWrite);
                CloseOwnedHandle(ref stderrWrite);

                // test-only delayでCreateProcess/Job assign中のdeadline消費を
                // 決定的に再現し、resume直前の同一clock判定をself-testする。
                if (String.Equals(
                    testFailureMode,
                    "deadline",
                    StringComparison.Ordinal))
                {
                    System.Threading.Thread.Sleep(50);
                }

                var targetReleased = false;
                if (deadlineClock.ElapsedMilliseconds < deadlineMilliseconds)
                {
                    // Job割当後・resume前もtarget codeは未実行である。Job close
                    // cleanupとprocess tableからの消滅をself-testで実測する。
                    if (String.Equals(
                            testFailureMode,
                            "resume",
                            StringComparison.Ordinal) ||
                        String.Equals(
                            testFailureMode,
                            "resume-close",
                            StringComparison.Ordinal))
                    {
                        throw new InvalidOperationException(
                            "Synthetic ResumeThread failure.");
                    }
                    if (ResumeThread(processInformation.Thread) == ResumeFailed)
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "ResumeThread failed.");
                    }
                    targetReleased = true;
                    if (String.Equals(
                        testFailureMode,
                        "deadline",
                        StringComparison.Ordinal))
                    {
                        // deadline checkをmutationで除いた場合にtarget sentinelが
                        // 確実に観測可能になるまで、test seam内だけで待つ。
                        System.Threading.Thread.Sleep(100);
                    }
                }
                CloseOwnedHandle(ref processInformation.Thread);

                var result = new ContainedProcess(
                    processInformation.Process,
                    stdin,
                    stdout,
                    stderr,
                    job,
                    targetReleased,
                    String.Equals(
                        testFailureMode,
                        "close",
                        StringComparison.Ordinal)
                        ? 2
                        : 0);
                processInformation.Process = IntPtr.Zero;
                stdin = null;
                stdout = null;
                stderr = null;
                job = IntPtr.Zero;
                return result;
            }
            catch (Exception launchFailure)
            {
                Exception cleanupFailure = null;
                if (processCreated)
                {
                    if (processAssigned && job != IntPtr.Zero)
                    {
                        // close failure時はhandleをfinallyの再試行用に残し、
                        // suspended processを直接terminateするfallbackも要求する。
                        var assignedJob = job;
                        var syntheticCloseFailure = String.Equals(
                            testFailureMode,
                            "resume-close",
                            StringComparison.Ordinal);
                        if (!syntheticCloseFailure &&
                            CloseHandle(assignedJob))
                        {
                            job = IntPtr.Zero;
                        }
                        else
                        {
                            cleanupFailure = syntheticCloseFailure
                                ? (Exception)new InvalidOperationException(
                                    "Synthetic assigned Job close failure.")
                                : new Win32Exception(
                                    Marshal.GetLastWin32Error(),
                                    "Closing the assigned Job failed.");
                            if (!TerminateProcess(
                                processInformation.Process,
                                1))
                            {
                                var terminateFailure =
                                    new Win32Exception(
                                        Marshal.GetLastWin32Error(),
                                        "Fallback process termination failed.");
                                cleanupFailure = new AggregateException(
                                    cleanupFailure,
                                    terminateFailure);
                            }
                        }
                    }
                    else if (!TerminateProcess(
                        processInformation.Process,
                        1))
                    {
                        cleanupFailure = new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "Terminating the suspended process failed.");
                    }
                    var waitResult = WaitForSingleObject(
                        processInformation.Process,
                        5000);
                    if (waitResult != WaitObject0)
                    {
                        Exception waitFailure = waitResult == WaitFailed
                            ? (Exception)new Win32Exception(
                                Marshal.GetLastWin32Error(),
                                "Waiting for launch-failure cleanup failed.")
                            : new TimeoutException(
                                "Launch-failure cleanup exceeded 5000 ms.");
                        cleanupFailure = cleanupFailure == null
                            ? waitFailure
                            : new AggregateException(
                                cleanupFailure,
                                waitFailure);
                    }
                }
                if (cleanupFailure != null)
                {
                    primaryFailure = new AggregateException(
                        "Contained child launch cleanup failed.",
                        launchFailure,
                        cleanupFailure);
                    throw primaryFailure;
                }
                primaryFailure = launchFailure;
                throw;
            }
            finally
            {
                // cleanupごとに例外境界を分け、先頭のclose/Dispose失敗でも
                // 後続resourceを全て試す。primary failureは必ずaggregateへ残す。
                Exception finalCleanupFailure = null;
                if (environmentBlock != IntPtr.Zero)
                {
                    CaptureCleanupFailure(
                        () => Marshal.FreeHGlobal(environmentBlock),
                        ref finalCleanupFailure);
                }
                if (attributeListInitialized)
                {
                    CaptureCleanupFailure(
                        () => DeleteProcThreadAttributeList(attributeList),
                        ref finalCleanupFailure);
                }
                if (attributeList != IntPtr.Zero)
                {
                    CaptureCleanupFailure(
                        () => Marshal.FreeHGlobal(attributeList),
                        ref finalCleanupFailure);
                }
                if (inheritedHandleList != IntPtr.Zero)
                {
                    CaptureCleanupFailure(
                        () => Marshal.FreeHGlobal(inheritedHandleList),
                        ref finalCleanupFailure);
                }
                CaptureOwnedHandleClose(
                    ref stdinRead,
                    ref finalCleanupFailure);
                CaptureOwnedHandleClose(
                    ref stdinWrite,
                    ref finalCleanupFailure);
                CaptureOwnedHandleClose(
                    ref stdoutRead,
                    ref finalCleanupFailure);
                CaptureOwnedHandleClose(
                    ref stdoutWrite,
                    ref finalCleanupFailure);
                CaptureOwnedHandleClose(
                    ref stderrRead,
                    ref finalCleanupFailure);
                CaptureOwnedHandleClose(
                    ref stderrWrite,
                    ref finalCleanupFailure);
                CaptureOwnedHandleClose(
                    ref processInformation.Thread,
                    ref finalCleanupFailure);
                CaptureOwnedHandleClose(
                    ref processInformation.Process,
                    ref finalCleanupFailure);
                if (job != IntPtr.Zero)
                {
                    CaptureCleanupFailure(
                        () => {
                            ProcessBoundary.Close(job);
                            job = IntPtr.Zero;
                        },
                        ref finalCleanupFailure);
                }
                if (stdin != null)
                {
                    CaptureCleanupFailure(
                        () => stdin.Dispose(),
                        ref finalCleanupFailure);
                }
                if (stdout != null)
                {
                    CaptureCleanupFailure(
                        () => stdout.Dispose(),
                        ref finalCleanupFailure);
                }
                if (stderr != null)
                {
                    CaptureCleanupFailure(
                        () => stderr.Dispose(),
                        ref finalCleanupFailure);
                }
                if (finalCleanupFailure != null)
                {
                    if (primaryFailure != null)
                    {
                        throw new AggregateException(
                            "Contained child launch and cleanup failed.",
                            primaryFailure,
                            finalCleanupFailure);
                    }
                    throw new AggregateException(
                        "Contained child cleanup failed.",
                        finalCleanupFailure);
                }
            }
        }

        public bool WaitForExit(int milliseconds)
        {
            return WaitForSingleObject(
                processHandle,
                (uint)milliseconds) == WaitObject0;
        }

        public bool HasExited
        {
            get {
                return WaitForSingleObject(processHandle, 0) == WaitObject0;
            }
        }

        public int ExitCode
        {
            get
            {
                uint exitCode;
                if (!GetExitCodeProcess(processHandle, out exitCode))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return unchecked((int)exitCode);
            }
        }

        public void CloseJob()
        {
            if (jobHandle == IntPtr.Zero)
            {
                return;
            }
            var handle = jobHandle;
            Exception closeFailure = null;
            try
            {
                if (syntheticJobCloseFailuresRemaining > 0)
                {
                    syntheticJobCloseFailuresRemaining--;
                    throw new InvalidOperationException(
                        "Synthetic Job close failure.");
                }
                ProcessBoundary.Close(handle);
                // CloseHandle成功後だけownershipを手放す。失敗時は後続の
                // Stop/Dispose/finalizerが同じhandleを安全に再試行する。
                jobHandle = IntPtr.Zero;
                return;
            }
            catch (Exception failure)
            {
                closeFailure = failure;
            }

            try
            {
                // KILL_ON_JOB_CLOSE自体が発火しない異常でも、保持中のJob
                // handleからtree全体の停止を試みて副作用を閉じ込める。
                ProcessBoundary.Terminate(handle);
            }
            catch (Exception terminateFailure)
            {
                throw new AggregateException(
                    "Closing and terminating the contained Job failed.",
                    closeFailure,
                    terminateFailure);
            }
            throw closeFailure;
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            // 各resourceを独立して回収し、先頭例外で後続stream/native handleを
            // skipしない。失敗時はdisposed=falseとownershipを保持して再試行可能にする。
            Exception cleanupFailure = null;
            CaptureCleanupFailure(
                () => CloseJob(),
                ref cleanupFailure);
            CaptureCleanupFailure(
                () => StandardInput.Dispose(),
                ref cleanupFailure);
            CaptureCleanupFailure(
                () => StandardOutput.Dispose(),
                ref cleanupFailure);
            CaptureCleanupFailure(
                () => StandardError.Dispose(),
                ref cleanupFailure);
            CaptureOwnedHandleClose(
                ref processHandle,
                ref cleanupFailure);
            if (cleanupFailure != null)
            {
                throw new AggregateException(
                    "Contained process cleanup failed.",
                    cleanupFailure);
            }
            disposed = true;
            GC.SuppressFinalize(this);
        }
    }

    public static class PosixSignal
    {
        private const int SigKill = 9;
        private const int ErrorNoSuchProcess = 3;

        [DllImport("libc", SetLastError = true)]
        private static extern int kill(int pid, int signal);

        [DllImport("libc", SetLastError = true)]
        private static extern int getpgid(int pid);

        public static bool IsSuccessfulResult(int result, int error)
        {
            return result == 0 ||
                (result == -1 && error == ErrorNoSuchProcess);
        }

        public static bool IsProcessGroupLeader(int processId)
        {
            return processId > 0 && getpgid(processId) == processId;
        }

        public static bool KillProcessGroup(int processGroupId)
        {
            if (processGroupId <= 0)
            {
                return false;
            }

            var result = kill(-processGroupId, SigKill);
            var error = result == 0 ? 0 : Marshal.GetLastWin32Error();
            return IsSuccessfulResult(result, error);
        }
    }
}
'@
}

function Test-PrivateMarkerWindowsHost {
    try {
        return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows
        )
    }
    catch {
        # RuntimeInformation が無い旧hostでも、ambient変数ではなくruntime特性を使う。
        return [System.IO.Path]::DirectorySeparatorChar -eq [char]92
    }
}

function Test-PrivateMarkerByteArraysEqual {
    param(
        [byte[]]$Expected,
        [byte[]]$Actual
    )

    if ($Expected.Length -ne $Actual.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            return $false
        }
    }
    return $true
}

function ConvertTo-PrivateMarkerProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    if ([string]::IsNullOrEmpty($Argument)) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # PowerShell 5.1 には ArgumentList がないため、native 引数規則で引用する。
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (($backslashes * 2) + 1))
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, ($backslashes * 2))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Get-PrivateMarkerPosixSetsidArguments {
    param(
        [string]$PowerShellExecutable,
        [string]$EncodedCommand
    )

    # BusyBox / util-linuxの共通契約は先頭operandのprogram pathだけに絞る。
    # util-linux固有optionを追加するとBusyBox hostが常時fail closedになる。
    return [string[]]@(
        $PowerShellExecutable,
        '-NoProfile',
        '-EncodedCommand',
        $EncodedCommand
    )
}

function Set-PrivateMarkerHermeticGitEnvironment {
    param(
        [System.Collections.IDictionary]$Environment,
        [string]$IsolationRoot,
        [string]$ExecutablePath
    )

    # sanitized Git child はdenylistではなく最小allowlistから組み立てる。
    # 非Git名のcredential・marker・loader変数も含め、親のambient値を渡さない。
    if (-not [System.IO.Path]::IsPathRooted($ExecutablePath) -or
        -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        throw 'Sanitized Git executable must be an existing absolute file.'
    }
    $executableDirectory = Split-Path -Parent (
        [System.IO.Path]::GetFullPath($ExecutablePath)
    )
    $Environment.Clear()

    $homeDirectory = Join-Path $IsolationRoot 'home'
    $xdgDirectory = Join-Path $IsolationRoot 'xdg'
    $temporaryDirectory = Join-Path $IsolationRoot 'tmp'
    $hooksDirectory = Join-Path $IsolationRoot 'empty-hooks'
    $templateDirectory = Join-Path $IsolationRoot 'empty-template'
    foreach ($directory in @(
        $homeDirectory,
        $xdgDirectory,
        $temporaryDirectory,
        $hooksDirectory,
        $templateDirectory
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $emptyGlobalConfig = Join-Path $IsolationRoot 'empty-global.gitconfig'
    $emptySystemConfig = Join-Path $IsolationRoot 'empty-system.gitconfig'
    $emptyAttributes = Join-Path $IsolationRoot 'empty-attributes'
    $emptyExcludes = Join-Path $IsolationRoot 'empty-excludes'
    foreach ($emptyFile in @($emptyGlobalConfig, $emptySystemConfig, $emptyAttributes, $emptyExcludes)) {
        if (-not (Test-Path -LiteralPath $emptyFile -PathType Leaf)) {
            [System.IO.File]::WriteAllText($emptyFile, '', [System.Text.UTF8Encoding]::new($false))
        }
    }

    # PATHはtarget自身のdirectoryと固定OS directoryだけに限定する。
    # credential helperや任意のshimをambient PATHから解決させない。
    $safePathEntries = New-Object System.Collections.Generic.List[string]
    $safePathEntries.Add($executableDirectory) | Out-Null
    if (Test-PrivateMarkerWindowsHost) {
        $systemDirectory = [Environment]::SystemDirectory
        if (-not [string]::IsNullOrWhiteSpace($systemDirectory) -and
            (Test-Path -LiteralPath $systemDirectory -PathType Container)) {
            $safePathEntries.Add($systemDirectory) | Out-Null
            $windowsDirectory = Split-Path -Parent $systemDirectory
            $Environment['SystemRoot'] = $windowsDirectory
            $Environment['WINDIR'] = $windowsDirectory
            $Environment['ComSpec'] = Join-Path $systemDirectory 'cmd.exe'
        }
        $Environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
        $Environment['TEMP'] = $temporaryDirectory
        $Environment['TMP'] = $temporaryDirectory
    } else {
        foreach ($systemPath in @('/usr/bin', '/bin')) {
            if (Test-Path -LiteralPath $systemPath -PathType Container) {
                $safePathEntries.Add($systemPath) | Out-Null
            }
        }
        $Environment['TMPDIR'] = $temporaryDirectory
        $Environment['TEMP'] = $temporaryDirectory
        $Environment['TMP'] = $temporaryDirectory
    }
    $Environment['PATH'] = @($safePathEntries | Select-Object -Unique) -join (
        [System.IO.Path]::PathSeparator
    )

    $Environment['HOME'] = $homeDirectory
    $Environment['USERPROFILE'] = $homeDirectory
    $Environment['XDG_CONFIG_HOME'] = $xdgDirectory
    $Environment['LC_ALL'] = 'C'
    $Environment['LANG'] = 'C'
    $Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $Environment['GIT_ATTR_NOSYSTEM'] = '1'
    $Environment['GIT_CONFIG_GLOBAL'] = $emptyGlobalConfig
    $Environment['GIT_CONFIG_SYSTEM'] = $emptySystemConfig
    $Environment['GIT_TERMINAL_PROMPT'] = '0'
    $Environment['GIT_OPTIONAL_LOCKS'] = '0'
    $Environment['GIT_LFS_SKIP_SMUDGE'] = '1'
    # Partial clone の不足 object を取得したり replace ref で別 blob へ差し替えたりすると、
    # local-only scan が network / repository write を起こすため、全 Git 子で明示的に無効化する。
    $Environment['GIT_NO_LAZY_FETCH'] = '1'
    $Environment['GIT_NO_REPLACE_OBJECTS'] = '1'

    $safeConfig = @(
        [pscustomobject]@{ Key = 'core.hooksPath'; Value = $hooksDirectory },
        [pscustomobject]@{ Key = 'core.attributesFile'; Value = $emptyAttributes },
        [pscustomobject]@{ Key = 'core.excludesFile'; Value = $emptyExcludes },
        [pscustomobject]@{ Key = 'core.fsmonitor'; Value = 'false' },
        [pscustomobject]@{ Key = 'init.templateDir'; Value = $templateDirectory }
    )
    $Environment['GIT_CONFIG_COUNT'] = [string]$safeConfig.Count
    for ($index = 0; $index -lt $safeConfig.Count; $index++) {
        $Environment["GIT_CONFIG_KEY_$index"] = $safeConfig[$index].Key
        $Environment["GIT_CONFIG_VALUE_$index"] = $safeConfig[$index].Value
    }
}

function Stop-PrivateMarkerPosixProcessGroup {
    param([int]$ProcessGroupId)

    # kill utility の exit 1 では ESRCH と EPERM を区別できない。
    # libc の errno を直接読み、既に消滅した group だけを成功として扱う。
    return [PrivateMarker.PosixSignal]::KillProcessGroup($ProcessGroupId)
}

function Stop-PrivateMarkerProcessTree {
    param(
        [System.Diagnostics.Process]$Process = $null,
        [PrivateMarker.ContainedProcess]$ContainedProcess = $null,
        [IntPtr]$JobHandle,
        [int]$PosixProcessGroupId = 0,
        [int]$WaitMilliseconds = 5000
    )

    if ($null -ne $ContainedProcess) {
        $jobClosed = $false
        try {
            $ContainedProcess.CloseJob()
            $jobClosed = $true
        }
        catch {
            $jobClosed = $false
        }
        if (-not $ContainedProcess.HasExited) {
            [void]$ContainedProcess.WaitForExit($WaitMilliseconds)
        }
        return [pscustomobject]@{
            JobClosed = $jobClosed
            ProcessExited = $ContainedProcess.HasExited
        }
    }

    if ($PosixProcessGroupId -gt 0) {
        $groupStopped =
            Stop-PrivateMarkerPosixProcessGroup `
                -ProcessGroupId $PosixProcessGroupId
        if (-not $Process.HasExited) {
            [void]$Process.WaitForExit($WaitMilliseconds)
        }
        return [pscustomobject]@{
            JobClosed = $false
            # 呼出側の既存契約へ group signal の成否も畳み込み、
            # EPERM 等を TreeStopped=true として誤報しない。
            ProcessExited = $groupStopped -and $Process.HasExited
        }
    }

    $jobClosed = $false
    if ($JobHandle -ne [IntPtr]::Zero) {
        try {
            # KILL_ON_JOB_CLOSE で、親が終了済みでも pipe を持つ孫を停止する。
            [PrivateMarker.ProcessBoundary]::Close($JobHandle)
            $jobClosed = $true
        }
        catch {
            $jobClosed = $false
        }
    }

    if (-not $Process.HasExited) {
        if (-not $Process.WaitForExit($WaitMilliseconds)) {
            try {
                $killTreeMethod = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
                if ($null -ne $killTreeMethod) {
                    [void]$killTreeMethod.Invoke($Process, @($true))
                } elseif (Test-PrivateMarkerWindowsHost) {
                    $taskkillInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $taskkillInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
                    $taskkillInfo.Arguments = "/PID $($Process.Id) /T /F"
                    $taskkillInfo.UseShellExecute = $false
                    $taskkillInfo.CreateNoWindow = $true
                    $taskkill = [System.Diagnostics.Process]::Start($taskkillInfo)
                    try {
                        if (-not $taskkill.WaitForExit($WaitMilliseconds)) {
                            $taskkill.Kill()
                            [void]$taskkill.WaitForExit($WaitMilliseconds)
                        }
                    }
                    finally {
                        $taskkill.Dispose()
                    }
                } else {
                    $Process.Kill()
                }
            }
            catch {
                if (-not $Process.HasExited) {
                    try { $Process.Kill() } catch { }
                }
            }
        }
    }
    if (-not $Process.HasExited) {
        [void]$Process.WaitForExit($WaitMilliseconds)
    }

    return [pscustomobject]@{
        JobClosed = $jobClosed
        ProcessExited = $Process.HasExited
    }
}

function Wait-PrivateMarkerReadTask {
    param(
        [System.Threading.Tasks.Task]$Task,
        [int]$WaitMilliseconds
    )

    try {
        return $Task.Wait($WaitMilliseconds)
    }
    catch {
        return $false
    }
}

function Invoke-PrivateMarkerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$Arguments = @(),

        [byte[]]$StandardInputBytes = $null,

        [string]$WorkingDirectory = '',

        [hashtable]$EnvironmentOverrides = @{},

        [switch]$SanitizeGitEnvironment,

        [string]$IsolationRoot = '',

        [int]$TimeoutMilliseconds = 15000,

        [int]$MaximumStandardOutputBytes = 8388608,

        [int]$MaximumStandardErrorBytes = 1048576,

        [int]$MaximumStandardInputBytes = 16777216,

        # production caller の既定猶予は維持し、synthetic pipe fixture だけが
        # 同じ状態遷移を短い期限で検証できるよう lower-only にする。
        [ValidateRange(100, 2000)]
        [int]$StreamCompletionWaitMilliseconds = 250,

        [ValidateRange(250, 5000)]
        [int]$StreamCleanupWaitMilliseconds = 5000,

        # /usr/bin/setsid が無いPOSIX host向けnative gateをself-testで
        # 強制し、portable fallbackも同じcontainment契約で検証する。
        [switch]$ForceNativePosixSessionGate,

        # Windows suspended launchとJob close failure cleanupを検証する
        # self-test専用seam。production callerは常に空文字の既定値を使う。
        [ValidateSet('', 'assign', 'resume', 'resume-close', 'close', 'deadline')]
        [string]$ForceWindowsLaunchFailure = '',

        # POSIX ready protocolのPID/nonce/raw-byte/deadline違反を決定的に
        # 再現するself-test専用seam。production callerは空文字から変更しない。
        [ValidateSet('', 'forged-pid', 'forged-nonce', 'bom', 'partial', 'delay', 'release-delay')]
        [string]$ForcePosixGateFailure = ''
    )

    if ($SanitizeGitEnvironment -and [string]::IsNullOrWhiteSpace($IsolationRoot)) {
        throw 'IsolationRoot is required when SanitizeGitEnvironment is used.'
    }
    if ($null -ne $StandardInputBytes -and
        $StandardInputBytes.Length -gt $MaximumStandardInputBytes) {
        throw 'Standard input exceeds the bounded process byte limit.'
    }

    # environment準備、OS launch、POSIX gate、target待機を同じmonotonic
    # deadlineへ含める。tree/stream cleanupの有限猶予だけは別枠で保持する。
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $process = $null
    $containedProcess = $null
    $processStarted = $false
    $containmentEstablished = $false
    $posixProcessGroupId = 0
    $posixGateReadyPath = $null
    $posixGateReleasePath = $null
    $stdinStream = $null
    $stdoutStream = $null
    $stderrStream = $null
    $stdinTask = $null
    $stdinClosed = $false
    $inputWriteFailed = $false
    $stdoutTask = $null
    $stderrTask = $null
    $timedOut = $false
    $outputLimitExceeded = $false
    $pipeLeakDetected = $false
    $treeStopped = $true
    $exitCode = -1
    $stdoutBytes = New-Object byte[] 0
    $stderrBytes = New-Object byte[] 0
    $primaryProcessFailure = $null
    $cleanupFailures =
        New-Object System.Collections.Generic.List[System.Exception]

    try {
        # 子へ渡す environment は親 process の clone から作り、親自身は変更しない。
        $childEnvironment = @{}
        $processEnvironment = [Environment]::GetEnvironmentVariables('Process')
        foreach ($name in $processEnvironment.Keys) {
            $childEnvironment["$name"] = [string]$processEnvironment[$name]
        }
        foreach ($name in $EnvironmentOverrides.Keys) {
            # `$null` は child だけの unset を表す。ambient OS 判定などの
            # absent / present-empty / forged 値を親環境へ触れず検証できる。
            if ($null -eq $EnvironmentOverrides[$name]) {
                [void]$childEnvironment.Remove("$name")
            } else {
                $childEnvironment["$name"] =
                    [string]$EnvironmentOverrides[$name]
            }
        }
        if ($SanitizeGitEnvironment) {
            # overrideも含むclone全体を最後に捨て、明示引数であっても
            # credential/marker/loader値をGit境界へ再注入できないようにする。
            Set-PrivateMarkerHermeticGitEnvironment `
                -Environment $childEnvironment `
                -IsolationRoot $IsolationRoot `
                -ExecutablePath $FileName
        }

        if (Test-PrivateMarkerWindowsHost) {
            try {
                # Direct target を suspended で作り、Job assign 後だけ resume する。
                $containedProcess = [PrivateMarker.ContainedProcess]::Start(
                    $FileName,
                    [string[]]$Arguments,
                    $childEnvironment,
                    $WorkingDirectory,
                    $ForceWindowsLaunchFailure,
                    $clock,
                    $TimeoutMilliseconds
                )
            }
            catch {
                if ($ForceWindowsLaunchFailure -ceq 'resume-close') {
                    # Windows PowerShell 5.1はAggregateException.Messageから
                    # inner fixed messagesを省略する。test-only seamでは実際の
                    # aggregateを検査し、primary/cleanupが各1回・順序どおり
                    # 残る場合だけpublic境界へ固定診断として再構成する。
                    $syntheticAggregate = $_.Exception
                    for ($aggregateDepth = 0;
                        $aggregateDepth -lt 8 -and
                        $null -ne $syntheticAggregate -and
                        $syntheticAggregate -isnot [AggregateException];
                        $aggregateDepth++) {
                        $syntheticAggregate =
                            $syntheticAggregate.InnerException
                    }
                    $syntheticMessages = @()
                    if ($syntheticAggregate -is [AggregateException]) {
                        $syntheticMessages = @(
                            $syntheticAggregate.Flatten().InnerExceptions |
                                ForEach-Object { [string]$_.Message }
                        )
                    }
                    $resumePrimaryMessage =
                        'Synthetic ResumeThread failure.'
                    $assignedJobCleanupMessage =
                        'Synthetic assigned Job close failure.'
                    if ($syntheticMessages.Count -eq 2 -and
                        $syntheticMessages[0] -ceq $resumePrimaryMessage -and
                        $syntheticMessages[1] -ceq
                            $assignedJobCleanupMessage) {
                        throw (
                            'Failed to start atomically contained child process: ' +
                            $resumePrimaryMessage + ' ' +
                            $assignedJobCleanupMessage
                        )
                    }
                    throw (
                        'Failed to start atomically contained child process: ' +
                        'synthetic launch aggregation contract failed.'
                    )
                }
                throw "Failed to start atomically contained child process: $($_.Exception.Message)"
            }
            $stdinStream = $containedProcess.StandardInput
            $stdoutStream = $containedProcess.StandardOutput
            $stderrStream = $containedProcess.StandardError
            $processStarted = $true
            $containmentEstablished = $true
            if (-not $containedProcess.TargetReleased) {
                # suspended targetをreleaseしなかった期限切れも通常のtimeout
                # resultへ畳み、finallyのJob cleanupでtreeを有限回収する。
                $timedOut = $true
            }
        } else {
            $effectiveFileName = $FileName
            $effectiveArguments = @($Arguments)
            $useNativePosixSessionGate = $false
            $setsidPath = @('/usr/bin/setsid', '/bin/setsid') |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($ForceNativePosixSessionGate -or
                [string]::IsNullOrWhiteSpace($setsidPath)) {
                # macOS等でsetsid executableが無い場合はwrapper自身がsetsid(2)を呼ぶ。
                $useNativePosixSessionGate = $true
            }

            # external setsid / native setsid のどちらも、session確立後の
            # direct launcher PID + launch nonceをatomic ready recordで返す。
            # 同じPIDがPGIDであることを親がkernelへ確認するまでtargetをreleaseしない。
            $gateRoot = if ([string]::IsNullOrWhiteSpace($IsolationRoot)) {
                [System.IO.Path]::GetTempPath()
            } else {
                $IsolationRoot
            }
            if (-not (Test-Path -LiteralPath $gateRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $gateRoot -Force |
                    Out-Null
            }
            $gateId = [Guid]::NewGuid().ToString('N')
            $gateNonce = [Guid]::NewGuid().ToString('N')
            $posixGateReadyPath =
                Join-Path $gateRoot "private-marker-posix-ready-$gateId"
            $posixGateReleasePath =
                Join-Path $gateRoot "private-marker-posix-release-$gateId"
            $payloadJson = [pscustomobject]@{
                FileName = $FileName
                Arguments = @($Arguments)
            } | ConvertTo-Json -Compress -Depth 4
            $payloadBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
            )
            $readyPathBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($posixGateReadyPath)
            )
            $releasePathBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($posixGateReleasePath)
            )
            $readyNonceBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::ASCII.GetBytes($gateNonce)
            )
            $readyFailureBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::ASCII.GetBytes(
                    $ForcePosixGateFailure
                )
            )
            $posixWrapperTemplate = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (__CREATE_SESSION__) {
    if ($null -eq ('PrivateMarker.NativePosixSession' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;

namespace PrivateMarker
{
    public static class NativePosixSession
    {
        [DllImport("libc", SetLastError = true)]
        private static extern int setsid();

        public static int Create()
        {
            return setsid();
        }
    }
}
"@
    }
}
try {
    if (__CREATE_SESSION__) {
        if ([PrivateMarker.NativePosixSession]::Create() -lt 0) {
            [Console]::Error.WriteLine('Bounded POSIX session setup failed.')
            exit 126
        }
    }
    $readyPath = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__READY_PATH__')
    )
    $releasePath = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__RELEASE_PATH__')
    )
    $readyNonce = [Text.Encoding]::ASCII.GetString(
        [Convert]::FromBase64String('__READY_NONCE__')
    )
    $readyFailure = [Text.Encoding]::ASCII.GetString(
        [Convert]::FromBase64String('__READY_FAILURE__')
    )
    if ($readyFailure -ceq 'delay') {
        Start-Sleep -Milliseconds 250
    }
    $currentProcessId = [Diagnostics.Process]::GetCurrentProcess().Id
    $readyProcessId = if ($readyFailure -ceq 'forged-pid') {
        $currentProcessId + 1
    } else {
        $currentProcessId
    }
    # PIDとrecord長が正しくてもlaunch nonceが一致しなければ、別launchの
    # stale/forged readyとして親が必ず拒否できるfixtureを作る。
    $readyRecordNonce = if ($readyFailure -ceq 'forged-nonce') {
        $replacementPrefix = if ($readyNonce[0] -ceq '0') { '1' } else { '0' }
        $replacementPrefix + $readyNonce.Substring(1)
    } else {
        $readyNonce
    }
    $readyRecord = (
        $readyProcessId.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ) + ':' + $readyRecordNonce
    )
    [byte[]]$readyBytes = [Text.Encoding]::ASCII.GetBytes($readyRecord)
    if ($readyFailure -ceq 'bom') {
        [byte[]]$readyBytes =
            @([byte]0xEF, [byte]0xBB, [byte]0xBF) + @($readyBytes)
    } elseif ($readyFailure -ceq 'partial') {
        [byte[]]$readyBytes = [Text.Encoding]::ASCII.GetBytes(
            $readyProcessId.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
        )
    }
    # temp siblingを完全writeしてからrenameし、readerへpartial recordを見せない。
    $readyTempPath =
        $readyPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($readyTempPath, $readyBytes)
        [IO.File]::Move($readyTempPath, $readyPath)
    }
    finally {
        if ([IO.File]::Exists($readyTempPath)) {
            [IO.File]::Delete($readyTempPath)
        }
    }
    $released = $false
    for ($gateAttempt = 0; $gateAttempt -lt 3000; $gateAttempt++) {
        if ([IO.File]::Exists($releasePath)) {
            $released = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    if (-not $released) {
        exit 124
    }
    $payloadJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__PAYLOAD__')
    )
    $payload = ConvertFrom-Json -InputObject $payloadJson
    $invokeArguments = @($payload.Arguments | ForEach-Object { [string]$_ })
    & ([string]$payload.FileName) @invokeArguments
    $childExitCode = $LASTEXITCODE
    if ($null -eq $childExitCode) {
        $childExitCode = 0
    }
    exit [int]$childExitCode
}
catch {
    [Console]::Error.WriteLine('Bounded child launch failed.')
    exit 127
}
'@
            $createSessionLiteral = if ($useNativePosixSessionGate) {
                '$true'
            } else {
                '$false'
            }
            $posixWrapperScript = $posixWrapperTemplate.Replace(
                '__CREATE_SESSION__',
                $createSessionLiteral
            ).Replace(
                '__READY_PATH__',
                $readyPathBase64
            ).Replace(
                '__RELEASE_PATH__',
                $releasePathBase64
            ).Replace(
                '__READY_NONCE__',
                $readyNonceBase64
            ).Replace(
                '__READY_FAILURE__',
                $readyFailureBase64
            ).Replace(
                '__PAYLOAD__',
                $payloadBase64
            )
            $posixWrapperBase64 = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes(
                    $posixWrapperScript
                )
            )
            $currentPowerShellExecutable = (
                [System.Diagnostics.Process]::GetCurrentProcess()
            ).MainModule.FileName
            if ($useNativePosixSessionGate) {
                $effectiveFileName = $currentPowerShellExecutable
                $effectiveArguments = @(
                    '-NoProfile',
                    '-EncodedCommand',
                    $posixWrapperBase64
                )
            } else {
                # util-linux固有optionを使わず、BusyBoxを含むportableなoperand形にする。
                # Process.Start直後のchildは親groupを継承し、自身がgroup leaderでは
                # ないためsetsidはforkせずwrapperへexecする。実PGIDはreadyで再確認する。
                $effectiveFileName = $setsidPath
                $effectiveArguments =
                    Get-PrivateMarkerPosixSetsidArguments `
                        -PowerShellExecutable $currentPowerShellExecutable `
                        -EncodedCommand $posixWrapperBase64
            }

            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $effectiveFileName
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
                $startInfo.WorkingDirectory = $WorkingDirectory
            }
            $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
            if ($null -ne $argumentListProperty) {
                foreach ($argument in $effectiveArguments) {
                    $startInfo.ArgumentList.Add($argument)
                }
            } else {
                $startInfo.Arguments = (
                    $effectiveArguments | ForEach-Object {
                        ConvertTo-PrivateMarkerProcessArgument -Argument $_
                    }
                ) -join ' '
            }
            $startInfo.EnvironmentVariables.Clear()
            foreach ($name in $childEnvironment.Keys) {
                $startInfo.EnvironmentVariables["$name"] =
                    [string]$childEnvironment[$name]
            }

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $processStarted = $process.Start()
            if (-not $processStarted) {
                throw "Failed to start bounded child process: $FileName"
            }
            $posixGateReady = $false
            $readyProcessId = 0
            $posixGateRecordRejected = $false
            $expectedReadyRecord = (
                $process.Id.ToString(
                    [System.Globalization.CultureInfo]::InvariantCulture
                ) + ':' + $gateNonce
            )
            [byte[]]$expectedReadyBytes =
                [System.Text.Encoding]::ASCII.GetBytes(
                    $expectedReadyRecord
                )
            while ($clock.ElapsedMilliseconds -lt
                $TimeoutMilliseconds) {
                if ([System.IO.File]::Exists($posixGateReadyPath)) {
                    try {
                        [byte[]]$actualReadyBytes =
                            [System.IO.File]::ReadAllBytes(
                                $posixGateReadyPath
                            )
                        if (Test-PrivateMarkerByteArraysEqual `
                                -Expected $expectedReadyBytes `
                                -Actual $actualReadyBytes) {
                            $readyProcessText =
                                [System.Text.Encoding]::ASCII.GetString(
                                    $actualReadyBytes
                                )
                            $readyProcessText = $readyProcessText.Substring(
                                0,
                                $readyProcessText.IndexOf(':')
                            )
                            if ([int]::TryParse(
                                $readyProcessText,
                                [System.Globalization.NumberStyles]::None,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [ref]$readyProcessId
                            ) -and
                                $readyProcessId -eq $process.Id) {
                                $posixGateReady = $true
                            }
                        } else {
                            $posixGateRecordRejected = $true
                        }
                        break
                    }
                    catch {
                        # atomic rename後でも外部lockがあればdeadline内で再読する。
                    }
                }
                if ($process.HasExited) {
                    break
                }
                $remainingGateMilliseconds =
                    $TimeoutMilliseconds -
                    $clock.ElapsedMilliseconds
                if ($remainingGateMilliseconds -le 0) {
                    break
                }
                Start-Sleep -Milliseconds (
                    [Math]::Min(5, [int]$remainingGateMilliseconds)
                )
            }
            if (-not $posixGateReady -or
                $posixGateRecordRejected -or
                $readyProcessId -ne $process.Id -or
                -not [PrivateMarker.PosixSignal]::IsProcessGroupLeader(
                    $readyProcessId
                )) {
                # gate/startup deadline後のtree回収は別枠の短い猶予で行い、
                # 旧固定10秒pollや既定5秒waitをpublic timeoutへ足さない。
                [void](Stop-PrivateMarkerProcessTree `
                    -Process $process `
                    -WaitMilliseconds 250)
                throw 'Failed to establish the bounded POSIX session gate.'
            }
            # direct launcher PID + nonceのexact recordと実PGIDを確認後だけ
            # releaseし、別process groupへのsignal誤配送を防ぐ。
            $posixProcessGroupId = $readyProcessId
            $containmentEstablished = $true
            if ($ForcePosixGateFailure -ceq 'release-delay') {
                Start-Sleep -Milliseconds 600
            }
            if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                # PGID検証中に期限を跨いだ場合もrelease fileを書かず、
                # verified groupを通常のtimeout cleanupへ渡す。
                $timedOut = $true
            } else {
                try {
                    [System.IO.File]::WriteAllText(
                        $posixGateReleasePath,
                        'release',
                        [System.Text.UTF8Encoding]::new($false)
                    )
                    if ($ForcePosixGateFailure -ceq 'release-delay') {
                        # deadline checkをmutationで除いた場合だけtarget sentinelを
                        # 観測可能にするtest-only猶予。productionでは実行されない。
                        Start-Sleep -Milliseconds 100
                    }
                }
                catch {
                    [void](Stop-PrivateMarkerPosixProcessGroup `
                            -ProcessGroupId $posixProcessGroupId)
                    throw
                }
            }
            $stdinStream = $process.StandardInput.BaseStream
            $stdoutStream = $process.StandardOutput.BaseStream
            $stderrStream = $process.StandardError.BaseStream
        }

        $stdoutTask = [PrivateMarker.BoundedStreamReader]::ReadAsync(
            $stdoutStream,
            $MaximumStandardOutputBytes
        )
        $stderrTask = [PrivateMarker.BoundedStreamReader]::ReadAsync(
            $stderrStream,
            $MaximumStandardErrorBytes
        )

        $effectiveInputBytes = if ($null -eq $StandardInputBytes) {
            New-Object byte[] 0
        } else {
            $StandardInputBytes
        }
        if ($effectiveInputBytes.Length -eq 0) {
            $stdinStream.Dispose()
            $stdinClosed = $true
        } else {
            $stdinTask = $stdinStream.WriteAsync(
                $effectiveInputBytes,
                0,
                $effectiveInputBytes.Length
            )
        }
        $processHasExited = if ($null -ne $containedProcess) {
            $containedProcess.HasExited
        } else {
            $process.HasExited
        }
        while (-not $processHasExited -and
            $clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if (-not $stdinClosed -and
                $null -ne $stdinTask -and
                $stdinTask.IsCompleted) {
                if ($stdinTask.IsFaulted -or $stdinTask.IsCanceled) {
                    $inputWriteFailed = $true
                } else {
                    try {
                        $stdinStream.Dispose()
                    }
                    catch {
                        $inputWriteFailed = $true
                    }
                }
                $stdinClosed = $true
            }
            if (($stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $stdoutTask.Result.LimitExceeded) -or
                ($stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $stderrTask.Result.LimitExceeded) -or
                $inputWriteFailed -or
                $stdoutTask.IsFaulted -or
                $stderrTask.IsFaulted) {
                $outputLimitExceeded = $stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $stdoutTask.Result.LimitExceeded
                $outputLimitExceeded = $outputLimitExceeded -or (
                    $stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $stderrTask.Result.LimitExceeded
                )
                break
            }
            # 100msはpoll上限であって追加猶予ではない。callerの単一deadlineの
            # remainingへ縮め、短いtimeoutを固定waitで超過させない。
            $remainingProcessMilliseconds =
                $TimeoutMilliseconds - $clock.ElapsedMilliseconds
            if ($remainingProcessMilliseconds -le 0) {
                break
            }
            $processWaitMilliseconds =
                [Math]::Min(100, [int]$remainingProcessMilliseconds)
            if ($null -ne $containedProcess) {
                [void]$containedProcess.WaitForExit(
                    $processWaitMilliseconds
                )
            } else {
                [void]$process.WaitForExit(
                    $processWaitMilliseconds
                )
            }
            $processHasExited = if ($null -ne $containedProcess) {
                $containedProcess.HasExited
            } else {
                $process.HasExited
            }
        }

        if (-not $stdinClosed) {
            if ($null -ne $stdinTask -and
                $stdinTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                try {
                    $stdinStream.Dispose()
                }
                catch {
                    $inputWriteFailed = $true
                }
            } elseif ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
                $inputWriteFailed = $true
            }
            $stdinClosed = $true
        }

        $processHasExited = if ($null -ne $containedProcess) {
            $containedProcess.HasExited
        } else {
            $process.HasExited
        }
        if (-not $processHasExited -and
            $clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            $timedOut = $true
        }

        $needsTreeStop = $timedOut -or
            $outputLimitExceeded -or
            $inputWriteFailed -or
            $stdoutTask.IsFaulted -or
            $stderrTask.IsFaulted
        if ($needsTreeStop) {
            $stopResult = Stop-PrivateMarkerProcessTree `
                -Process $process `
                -ContainedProcess $containedProcess `
                -JobHandle ([IntPtr]::Zero) `
                -PosixProcessGroupId $posixProcessGroupId
            $treeStopped = $stopResult.ProcessExited -and (
                -not (Test-PrivateMarkerWindowsHost) -or $stopResult.JobClosed
            )
        }

        $processHasExited = if ($null -ne $containedProcess) {
            $containedProcess.HasExited
        } else {
            $process.HasExited
        }
        if ($processHasExited) {
            $exitCode = if ($null -ne $containedProcess) {
                $containedProcess.ExitCode
            } else {
                $process.ExitCode
            }
        }

        if ($null -ne $containedProcess -and $processHasExited) {
            # direct childの正常終了後もJobを保持すると、pipeを握る孫が
            # StreamCompletionWaitまで動けてしまう。即時closeで子孫を止め、
            # その後の有限waitはpure stream drainだけにする。
            $containedProcess.CloseJob()
        }

        # 親が正常終了しても、孫が pipe handle を保持すれば read task は終わらない。
        $stdoutInitiallyComplete = Wait-PrivateMarkerReadTask `
            -Task $stdoutTask `
            -WaitMilliseconds $StreamCompletionWaitMilliseconds
        $stderrInitiallyComplete = Wait-PrivateMarkerReadTask `
            -Task $stderrTask `
            -WaitMilliseconds $StreamCompletionWaitMilliseconds
        if (-not $stdoutInitiallyComplete -or -not $stderrInitiallyComplete) {
            $pipeLeakDetected = $true
            $processHasExited = if ($null -ne $containedProcess) {
                $containedProcess.HasExited
            } else {
                $process.HasExited
            }
            if ($null -ne $containedProcess -or
                $posixProcessGroupId -gt 0 -or
                -not $processHasExited) {
                $stopResult = Stop-PrivateMarkerProcessTree `
                    -Process $process `
                    -ContainedProcess $containedProcess `
                    -JobHandle ([IntPtr]::Zero) `
                    -PosixProcessGroupId $posixProcessGroupId
                $treeStopped = $treeStopped -and
                    $stopResult.ProcessExited -and (
                        -not (Test-PrivateMarkerWindowsHost) -or $stopResult.JobClosed
                    )
            } elseif (Test-PrivateMarkerWindowsHost) {
                $treeStopped = $false
            }
            [void](Wait-PrivateMarkerReadTask `
                    -Task $stdoutTask `
                    -WaitMilliseconds $StreamCleanupWaitMilliseconds)
            [void](Wait-PrivateMarkerReadTask `
                    -Task $stderrTask `
                    -WaitMilliseconds $StreamCleanupWaitMilliseconds)
        }

        if ($stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $stdoutBytes = $stdoutTask.Result.Data
            $outputLimitExceeded = $outputLimitExceeded -or $stdoutTask.Result.LimitExceeded
        }
        if ($stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $stderrBytes = $stderrTask.Result.Data
            $outputLimitExceeded = $outputLimitExceeded -or $stderrTask.Result.LimitExceeded
        }
    }
    catch {
        # finallyのcleanup失敗で元例外を置換しない。全resource回収後に
        # primary + cleanupを一つのAggregateExceptionとして返す。
        $primaryProcessFailure = $_.Exception
    }
    finally {
        if ($processStarted) {
            try {
                if ($null -ne $containedProcess) {
                    $stopResult = Stop-PrivateMarkerProcessTree `
                        -Process $process `
                        -ContainedProcess $containedProcess `
                        -JobHandle ([IntPtr]::Zero) `
                        -PosixProcessGroupId 0
                    $treeStopped = $treeStopped -and
                        $stopResult.ProcessExited -and (
                            $stopResult.JobClosed
                        )
                } elseif ($null -ne $process -and
                    $posixProcessGroupId -gt 0) {
                    # direct childが先に終了してもgroupは孫を指し続ける。
                    # finallyで必ずsignalし、pipeを持たない孫の副作用も止める。
                    $stopResult = Stop-PrivateMarkerProcessTree `
                        -Process $process `
                        -ContainedProcess $null `
                        -JobHandle ([IntPtr]::Zero) `
                        -PosixProcessGroupId $posixProcessGroupId
                    $treeStopped = $treeStopped -and
                        $stopResult.ProcessExited
                } elseif ($null -ne $process -and -not $process.HasExited) {
                    $stopResult = Stop-PrivateMarkerProcessTree `
                        -Process $process `
                        -ContainedProcess $null `
                        -JobHandle ([IntPtr]::Zero) `
                        -PosixProcessGroupId 0
                    $treeStopped =
                        $treeStopped -and $stopResult.ProcessExited
                }
            }
            catch {
                $treeStopped = $false
                $cleanupFailures.Add($_.Exception) | Out-Null
            }
        }
        if (-not $stdinClosed -and $null -ne $stdinStream) {
            try {
                $stdinStream.Dispose()
            }
            catch {
                $inputWriteFailed = $true
                $cleanupFailures.Add($_.Exception) | Out-Null
            }
            $stdinClosed = $true
        }
        if ($null -ne $containedProcess) {
            try {
                $containedProcess.Dispose()
            }
            catch {
                $cleanupFailures.Add($_.Exception) | Out-Null
            }
        }
        if ($null -ne $process) {
            try {
                $process.Dispose()
            }
            catch {
                $cleanupFailures.Add($_.Exception) | Out-Null
            }
        }
        foreach ($gatePath in @(
            $posixGateReadyPath,
            $posixGateReleasePath
        )) {
            if (-not [string]::IsNullOrWhiteSpace($gatePath)) {
                try {
                    [System.IO.File]::Delete($gatePath)
                }
                catch {
                    # gate artifactもresource ownershipの一部として集約し、
                    # primary failureを置換せずfail-closedへ返す。
                    $cleanupFailures.Add($_.Exception) | Out-Null
                }
            }
        }
    }

    if ($null -ne $primaryProcessFailure -or
        $cleanupFailures.Count -gt 0) {
        if ($null -ne $primaryProcessFailure -and
            $cleanupFailures.Count -eq 0) {
            throw $primaryProcessFailure
        }
        $allProcessFailures =
            New-Object System.Collections.Generic.List[System.Exception]
        if ($null -ne $primaryProcessFailure) {
            $allProcessFailures.Add($primaryProcessFailure) | Out-Null
        }
        foreach ($cleanupFailure in $cleanupFailures) {
            $allProcessFailures.Add($cleanupFailure) | Out-Null
        }
        throw [System.AggregateException]::new(
            'Bounded process execution or cleanup failed.',
            [System.Exception[]]$allProcessFailures.ToArray()
        )
    }

    $streamsCompleted = $null -ne $stdoutTask -and
        $null -ne $stderrTask -and
        $stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
        $stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
        -not $pipeLeakDetected

    return [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutputBytes = $stdoutBytes
        StandardErrorBytes = $stderrBytes
        TimedOut = $timedOut
        OutputLimitExceeded = $outputLimitExceeded
        InputWriteFailed = $inputWriteFailed
        PipeLeakDetected = $pipeLeakDetected
        StreamsCompleted = $streamsCompleted
        TreeStopped = $treeStopped
        ContainmentEstablished = $containmentEstablished
    }
}

function ConvertFrom-PrivateMarkerUtf8Bytes {
    param(
        [byte[]]$Bytes,
        [string]$Context
    )

    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            return $text.Substring(1)
        }
        return $text
    }
    catch [System.Text.DecoderFallbackException] {
        throw "$Context is not valid UTF-8."
    }
}
