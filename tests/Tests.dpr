{
  ConcurrentPool test runner.

    Free Pascal   fpc -Mdelphi -Sa -Fu../src -Fu. -FU<out> -o<out>/Tests Tests.dpr
    Delphi        open in the IDE and build; the uses clause carries the paths

  -Sa matters: the atomic counter's guard is an assertion, so without it the
  guard test cannot observe anything.

    Tests               everything
    Tests --no-guards   skips the one test that raises on purpose, so a
                        debugger session is not interrupted

  Exits non-zero if any assertion fails, and Halt(2) from the watchdog if a test
  overruns — which for this library means a deadlock, not slowness.
}
program Tests;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  { On Unix, Free Pascal needs a thread driver loaded before any unit that
    touches threads, or TThread aborts with runtime error 232. It has to come
    first, and applies only to FPC on Unix. }
  {$IF DEFINED(FPC) AND DEFINED(UNIX)}
  cthreads,
  {$IFEND}
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  { Every unit with its path, so the Delphi IDE needs nothing configured. Free
    Pascal resolves from -Fu and ignores these. }
  ConcurrentPool.Types in '../src/ConcurrentPool.Types.pas',
  ConcurrentPool.Atomic in '../src/ConcurrentPool.Atomic.pas',
  ConcurrentPool.Queue in '../src/ConcurrentPool.Queue.pas',
  ConcurrentPool.Worker in '../src/ConcurrentPool.Worker.pas',
  ConcurrentPool.Pool in '../src/ConcurrentPool.Pool.pas',
  ConcurrentPool.Testing in 'ConcurrentPool.Testing.pas',
  ConcurrentPool.Tests in 'ConcurrentPool.Tests.pas';

{ Reads --watchdog=N. FindCmdLineSwitch does not hand back a value, so the
  parameters are walked directly. }
function GetWatchdogArg: string;
var
  I: Integer;
  P: string;
const
  Prefix = '--watchdog=';
begin
  Result := '';
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    if (Length(P) > Length(Prefix)) and
       SameText(Copy(P, 1, Length(Prefix)), Prefix) then
      Exit(Copy(P, Length(Prefix) + 1, MaxInt));
  end;
end;

var
  Runner: TTestRunner;
  RunGuards: Boolean;
  WatchdogArg: string;
  WatchdogSeconds: Integer;
begin
  WriteLn('ConcurrentPool test suite');
  {$IFDEF FPC}
  WriteLn('compiler : Free Pascal');
  {$ELSE}
  WriteLn('compiler : Delphi');
  {$ENDIF}
  {$IFOPT C+}
  WriteLn('asserts  : on');
  {$ELSE}
  WriteLn('asserts  : OFF — build with -Sa, or the guard test proves nothing');
  {$ENDIF}

  RunGuards := not FindCmdLineSwitch('no-guards', ['-', '/'], True);
  if not RunGuards then
    WriteLn('guards   : skipped (--no-guards)')
  else
    WriteLn('guards   : on; one test raises EAssertionFailed on purpose, so a ' +
      'debugger will stop once');

  { Per test, not for the whole run. Sixty seconds by default: every test here
    finishes in well under a second, so an overrun means blocked, not slow.
    Configurable because a low value is how the watchdog itself gets verified —
    `Tests --watchdog=1` must halt with a named test rather than run to
    completion. }
  WatchdogSeconds := 60;
  WatchdogArg := GetWatchdogArg;
  if WatchdogArg <> '' then
    WatchdogSeconds := StrToIntDef(WatchdogArg, 60);
  WriteLn('watchdog : ', WatchdogSeconds, ' s per test');

  Runner := TTestRunner.Create;
  try
    Runner.StartWatchdog(WatchdogSeconds);
    RunTests(Runner, RunGuards);
    ExitCode := Runner.Finish;
  finally
    Runner.Free;
  end;
end.
