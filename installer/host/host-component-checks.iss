function RunHostStep(const FileName, Params, Step: String): Integer;
var
  ResultCode: Integer;
begin
  Log('Starting ' + Step);
  if not Exec(FileName, Params, ExpandConstant('{tmp}'), SW_HIDE,
      ewWaitUntilTerminated, ResultCode) then
    RaiseException(Step + ' could not start. Windows error ' + IntToStr(ResultCode) + '.');
  Result := ResultCode;
end;

procedure RequireHostStep(const FileName, Params, Step: String);
var
  ResultCode: Integer;
begin
  ResultCode := RunHostStep(FileName, Params, Step);
  if ResultCode <> 0 then
    RaiseException(Step + ' failed. Exit code ' + IntToStr(ResultCode) + '.');
end;

function TemporaryScript(const FileName: String): String;
begin
  ExtractTemporaryFile(FileName);
  Result := '-NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\' + FileName) + '"';
end;

function PrepareHostComponents(InstallSunshine: Boolean; var NeedsRestart: Boolean): String;
var
  PowerShell: String;
  ResultCode: Integer;
begin
  Result := '';
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  try
    if InstallSunshine then begin
      ExtractTemporaryFile('Sunshine-Windows-AMD64-installer.msi');
      ResultCode := RunHostStep(ExpandConstant('{sys}\msiexec.exe'),
        '/i "' + ExpandConstant('{tmp}\Sunshine-Windows-AMD64-installer.msi') +
        '" /qn /norestart REBOOT=ReallySuppress', 'Sunshine installation');
      if ResultCode = 3010 then begin
        NeedsRestart := True;
        Result := 'Sunshine requires a Windows restart. Restart, then run setup again.';
        Exit;
      end;
      if ResultCode <> 0 then
        RaiseException('Sunshine installation failed. Exit code ' + IntToStr(ResultCode) + '.');
    end;
    RequireHostStep(PowerShell, TemporaryScript('install-tailscale.ps1'),
      'Tailscale installation');
    RequireHostStep(PowerShell, TemporaryScript('finalize-host.ps1'),
      'Sunshine startup and readiness check');
  except
    Result := GetExceptionMessage;
  end;
end;
