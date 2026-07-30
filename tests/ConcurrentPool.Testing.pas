{
  ConcurrentPool — assertion runner with a watchdog.

  Same small runner as the sibling repos, plus one addition that this library
  needs and they do not: a WATCHDOG.

  Every hazard here fails by BLOCKING. A lost wakeup, a Close that cannot
  release its waiters, a self-join — none of them produce a wrong value, they
  produce a process that never returns. A test suite that hangs tells you
  nothing, burns the CI runner until the job times out, and names no culprit.

  So the runner records which test is in progress and a watchdog thread halts
  the process with that name if it overruns. A deadlock becomes:

      WATCHDOG: test "Close releases blocked producers" exceeded 60s

  which is a bug report. `timeout` in CI is the outer layer for a hang that
  beats the watchdog itself.
}
unit ConcurrentPool.Testing;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils, Classes, SyncObjs{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs{$ENDIF};

type
  TTestRunner = class
  strict private
    FPassed: Integer;
    FFailed: Integer;
    FSuiteName: string;
    FHeaderWritten: Boolean;
    FLock: TCriticalSection;
    FCurrentTest: string;
    FCurrentStart: UInt64;
    FWatchdog: TThread;
    FWatchdogLimit: Cardinal;
    procedure EnsureHeader;
    procedure Pass(const ATestName: string);
    procedure Fail(const ATestName, AExpected, AActual: string);
  private
    { Read by the watchdog thread, which lives in this unit. }
    function CurrentTestSnapshot(out AElapsedMs: Cardinal): string;
    function WatchdogLimitMs: Cardinal;
  public
    constructor Create;
    destructor Destroy; override;

    { Starts the watchdog. ALimitSeconds is per test, not for the whole run. }
    procedure StartWatchdog(ALimitSeconds: Cardinal);

    procedure Suite(const AName: string);

    { Names the test about to run, so the watchdog can report it. Called
      automatically by the assertions, and directly before a long block that
      makes no assertion of its own. }
    procedure Begins(const ATestName: string);

    procedure IsTrue(const ATestName: string; ACondition: Boolean);
    procedure IsFalse(const ATestName: string; ACondition: Boolean);
    procedure AreEqual(const ATestName: string; AExpected, AActual: Integer); overload;
    procedure AreEqual(const ATestName, AExpected, AActual: string); overload;

    function Finish: Integer;
    property Passed: Integer read FPassed;
    property Failed: Integer read FFailed;
  end;

implementation

uses
  ConcurrentPool.Types;

type
  TWatchdogThread = class(TThread)
  strict private
    FRunner: TTestRunner;
  protected
    procedure Execute; override;
  public
    constructor Create(ARunner: TTestRunner);
  end;

constructor TWatchdogThread.Create(ARunner: TTestRunner);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRunner := ARunner;
end;

procedure TWatchdogThread.Execute;
var
  Name: string;
  Gone: Cardinal;
  Limit: Cardinal;
begin
  Limit := FRunner.WatchdogLimitMs;
  while not Terminated do
  begin
    Name := FRunner.CurrentTestSnapshot(Gone);
    if (Name <> '') and (Gone > Limit) then
    begin
      WriteLn;
      WriteLn(Format('WATCHDOG: test "%s" exceeded %d s and is presumed ' +
        'deadlocked.', [Name, Limit div 1000]));
      WriteLn('This suite has no unbounded waits, so an overrun is a hang, ' +
        'not slowness.');
      Flush(Output);
      { Halt rather than raise: the blocked thread cannot be unwound from here,
        and a named exit beats a silent one. }
      Halt(2);
    end;
    Sleep(100);
  end;
end;

{ TTestRunner }

constructor TTestRunner.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FHeaderWritten := True;
  FWatchdogLimit := 0;
end;

destructor TTestRunner.Destroy;
begin
  if FWatchdog <> nil then
  begin
    FWatchdog.Terminate;
    FWatchdog.WaitFor;
    FWatchdog.Free;
  end;
  FLock.Free;
  inherited Destroy;
end;

procedure TTestRunner.StartWatchdog(ALimitSeconds: Cardinal);
begin
  FWatchdogLimit := ALimitSeconds * 1000;
  FWatchdog := TWatchdogThread.Create(Self);
  FWatchdog.Start;
end;

function TTestRunner.WatchdogLimitMs: Cardinal;
begin
  Result := FWatchdogLimit;
end;

function TTestRunner.CurrentTestSnapshot(out AElapsedMs: Cardinal): string;
begin
  FLock.Enter;
  try
    Result := FCurrentTest;
    if Result = '' then
      AElapsedMs := 0
    else
      AElapsedMs := Elapsed(FCurrentStart);
  finally
    FLock.Leave;
  end;
end;

procedure TTestRunner.Begins(const ATestName: string);
begin
  FLock.Enter;
  try
    FCurrentTest := ATestName;
    FCurrentStart := Ticks;
  finally
    FLock.Leave;
  end;
end;

procedure TTestRunner.Suite(const AName: string);
begin
  FSuiteName := AName;
  FHeaderWritten := False;
end;

procedure TTestRunner.EnsureHeader;
begin
  if FHeaderWritten then
    Exit;
  WriteLn;
  WriteLn(FSuiteName);
  FHeaderWritten := True;
end;

procedure TTestRunner.Pass(const ATestName: string);
begin
  EnsureHeader;
  Inc(FPassed);
  WriteLn('  ok      ', ATestName);
  Flush(Output);
  { Re-arm rather than disarm. An earlier version cleared the name here, which
    left the watchdog BLIND between assertions — and that is precisely where two
    of the negative builds hung, so the watchdog reported nothing and the run had
    to be killed from outside. Keeping it armed with the last completed
    assertion localises any hang to "whatever comes after this line". }
  Begins('(after) ' + ATestName);
end;

procedure TTestRunner.Fail(const ATestName, AExpected, AActual: string);
begin
  EnsureHeader;
  Inc(FFailed);
  WriteLn('  FAILED  ', ATestName);
  WriteLn('            expected: ', AExpected);
  WriteLn('            actual:   ', AActual);
  Flush(Output);
  Begins('(after) ' + ATestName);
end;

procedure TTestRunner.IsTrue(const ATestName: string; ACondition: Boolean);
begin
  if ACondition then
    Pass(ATestName)
  else
    Fail(ATestName, 'True', 'False');
end;

procedure TTestRunner.IsFalse(const ATestName: string; ACondition: Boolean);
begin
  if not ACondition then
    Pass(ATestName)
  else
    Fail(ATestName, 'False', 'True');
end;

procedure TTestRunner.AreEqual(const ATestName: string; AExpected, AActual: Integer);
begin
  if AExpected = AActual then
    Pass(ATestName)
  else
    Fail(ATestName, IntToStr(AExpected), IntToStr(AActual));
end;

procedure TTestRunner.AreEqual(const ATestName, AExpected, AActual: string);
begin
  if AExpected = AActual then
    Pass(ATestName)
  else
    Fail(ATestName, '"' + AExpected + '"', '"' + AActual + '"');
end;

function TTestRunner.Finish: Integer;
begin
  Begins('');
  WriteLn;
  WriteLn('----------------------------------------');
  WriteLn(Format('%d passed, %d failed, %d total',
    [FPassed, FFailed, FPassed + FFailed]));
  if FFailed = 0 then
    Result := 0
  else
    Result := 1;
end;

end.
