<#
    Net Doctor - Portable Network Troubleshooter & Auto-Fixer
    ----------------------------------------------------------
    A thorough, portable checkup that inspects every connection on a
    Windows PC the way a network engineer would: wired Ethernet, Wi-Fi,
    addressing, the local box, the path to the internet, DNS, NAT, web,
    security, and Windows network services.

    It then explains what is going on in everyday language and gives
    click-by-click steps to fix it. Optional -Fix applies safe repairs
    and logs every change.

    Designed to run from a USB stick on any Windows 10/11 PC. No install.
    Read-only checks work as a standard user; -Fix requests Administrator.

    USAGE
      NetDoctor.exe                 Diagnose only (default). Saves a report.
      NetDoctor.exe -Fix            Diagnose, then auto-fix safe issues (asks for admin).
      NetDoctor.exe -Fix -DryRun    Show exactly what -Fix WOULD change, change nothing.
      NetDoctor.exe -DeepFix        Also allow deeper fixes that may need a reboot.
      NetDoctor.exe -Quick          Skip the slowest tests (throughput, traceroute, MTU, scan).
      NetDoctor.exe -NoColor        Plain text.  -NoReport  no file.  -NoPause  don't wait.
      NetDoctor.exe -PingCount 40   More ping samples = more accurate loss/jitter.
#>

[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$DeepFix,
    [switch]$DryRun,
    [switch]$Quick,
    [switch]$NoColor,
    [switch]$NoReport,
    [switch]$NoPause,
    [switch]$Elevated,
    [int]$PingCount = 20
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
if ($DeepFix) { $Fix = $true }

$script:AppName    = 'Net Doctor'
$script:AppVersion = '3.1.0'
$script:StageTotal = 15
$script:StageNum   = 0

$script:Transcript   = New-Object System.Text.StringBuilder
$script:Findings     = New-Object System.Collections.Generic.List[object]
$script:Remediations = New-Object System.Collections.Generic.List[object]
$script:Actions      = New-Object System.Collections.Generic.List[object]
$script:Facts        = @{}

function Set-Fact { param([string]$Key, $Value) $script:Facts[$Key] = $Value }
function Get-Fact { param([string]$Key, $Default = $null) if ($script:Facts.ContainsKey($Key)) { return $script:Facts[$Key] } return $Default }

# ------------------------------------------------------------------------------
# Admin detection + self-elevation for -Fix
# ------------------------------------------------------------------------------
function Test-IsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
$isAdmin = Test-IsAdmin

if ($Fix -and -not $DryRun -and -not $isAdmin -and -not $Elevated) {
    Write-Host ""
    Write-Host "  Net Doctor needs Administrator rights to APPLY fixes." -ForegroundColor Yellow
    Write-Host "  Requesting elevation (a Windows UAC prompt will appear)..." -ForegroundColor Yellow
    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add('-Elevated')
    if ($Fix)      { $argList.Add('-Fix') }
    if ($DeepFix)  { $argList.Add('-DeepFix') }
    if ($Quick)    { $argList.Add('-Quick') }
    if ($NoColor)  { $argList.Add('-NoColor') }
    if ($NoReport) { $argList.Add('-NoReport') }
    $argList.Add('-PingCount'); $argList.Add("$PingCount")
    try {
        $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($self -match 'powershell(_ise)?\.exe$' -or $self -match 'pwsh\.exe$') {
            $scriptPath = $PSCommandPath; if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Definition }
            $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"") + $argList
            Start-Process -FilePath $self -Verb RunAs -ArgumentList $psArgs | Out-Null
        } else {
            Start-Process -FilePath $self -Verb RunAs -ArgumentList $argList | Out-Null
        }
        Write-Host "  An elevated Net Doctor window has been opened. You can close this one." -ForegroundColor Green
        Start-Sleep -Seconds 2
        return
    } catch {
        Write-Host "  Elevation was cancelled or failed - continuing in DIAGNOSE-ONLY mode." -ForegroundColor Red
        $Fix = $false
    }
}

# ------------------------------------------------------------------------------
# Findings + remediation registry
# ------------------------------------------------------------------------------
function Add-Finding {
    param(
        [ValidateSet('Critical','Warning','Good','Info')] [string]$Severity,
        [string]$Area, [string]$Message, [string]$Recommendation = '',
        [string]$PlainWhat = '',
        [string]$PlainWhy = '',
        [string[]]$Playbooks = @(),
        [int]$Priority = 50
    )
    $script:Findings.Add([pscustomobject]@{
        Severity=$Severity; Area=$Area; Message=$Message; Recommendation=$Recommendation
        PlainWhat=$PlainWhat; PlainWhy=$PlainWhy
        PlaybookList=((@($Playbooks | ForEach-Object { "$_" } | Where-Object { $_ -and $_.Length -ge 3 })) -join ',')
        Priority=$Priority
    })
}

function Add-Remediation {
    param(
        [string]$Area, [string]$Problem, [string]$ActionText,
        [scriptblock]$Fix, [string]$Revert = '',
        [switch]$NeedsReboot, [switch]$DeepOnly
    )
    foreach ($r in $script:Remediations) { if ($r.ActionText -eq $ActionText) { return } }
    $script:Remediations.Add([pscustomobject]@{
        Area=$Area; Problem=$Problem; ActionText=$ActionText; Fix=$Fix
        Revert=$Revert; NeedsReboot=[bool]$NeedsReboot; DeepOnly=[bool]$DeepOnly
    })
}

# ------------------------------------------------------------------------------
# Console helpers
# ------------------------------------------------------------------------------
function Get-Color { param([string]$s)
    switch ($s) { 'Critical'{'Red'} 'Warning'{'Yellow'} 'Good'{'Green'} default{'Gray'} } }

function Write-C {
    param([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline)
    if ($NoNewline) { [void]$script:Transcript.Append($Text) } else { [void]$script:Transcript.AppendLine($Text) }
    if ($NoColor) {
        if ($NoNewline) { Write-Host $Text -NoNewline } else { Write-Host $Text }
    } else {
        if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
    }
}

function Write-Rule { param([string]$Color='DarkCyan') Write-C ('=' * 78) $Color }

function Write-Section {
    param([string]$Title)
    $script:StageNum++
    $label = "{0}/{1}  {2}" -f $script:StageNum, $script:StageTotal, $Title
    Write-C ""; Write-Rule; Write-C ("  $label") 'Cyan'; Write-Rule
    try { $Host.UI.RawUI.WindowTitle = "Net Doctor  -  $label" } catch {}
}

function Write-KV {
    param([string]$Key,[string]$Value,[string]$Color='White')
    $width = 32
    $k = $Key; if ($k.Length -gt $width) { $k = $k.Substring(0,$width) }
    Write-C ("  " + $k.PadRight($width)) 'Gray' -NoNewline; Write-C ": " 'Gray' -NoNewline; Write-C ([string]$Value) $Color
}

function Write-Status { param([string]$Severity,[string]$Text)
    $tag = switch ($Severity) { 'Critical'{'[CRIT]'} 'Warning'{'[WARN]'} 'Good'{'[ OK ]'} default{'[INFO]'} }
    Write-C "  $tag " (Get-Color $Severity) -NoNewline; Write-C $Text 'Gray'
}

function Write-Wrap {
    param([string]$Text, [string]$Color='White', [int]$Width=74, [string]$Indent='  ')
    if (-not $Text) { return }
    $words = $Text -split '\s+'
    $line = $Indent
    foreach ($w in $words) {
        if (($line.Length + $w.Length + 1) -gt $Width -and $line.Trim().Length -gt 0) {
            Write-C $line $Color
            $line = $Indent + $w + ' '
        } else { $line += ($w + ' ') }
    }
    if ($line.Trim().Length) { Write-C $line.TrimEnd() $Color }
}

function Get-NetshValue {
    param([string[]]$Lines, [string]$Label)
    try {
        $escaped = [regex]::Escape($Label)
        $m = $Lines | Select-String -Pattern ("^\s*$escaped\s*:\s*(.+)$") | Select-Object -First 1
        if ($m) { return $m.Matches.Groups[1].Value.Trim() }
    } catch {}
    return ''
}

# ------------------------------------------------------------------------------
# Measurement utilities
# ------------------------------------------------------------------------------
function Measure-Ping {
    param([string]$Target,[int]$Count=10,[int]$TimeoutMs=1500)
    $rtts = New-Object System.Collections.Generic.List[double]; $sent=0; $recv=0
    $ping = New-Object System.Net.NetworkInformation.Ping; $buffer = New-Object byte[] 32
    for ($i=0; $i -lt $Count; $i++) {
        $sent++
        try { $r=$ping.Send($Target,$TimeoutMs,$buffer); if ($r.Status -eq 'Success'){ $recv++; $rtts.Add([double]$r.RoundtripTime) } } catch {}
        Start-Sleep -Milliseconds 60
    }
    $loss = if ($sent){ [math]::Round((($sent-$recv)/$sent)*100,1) } else { 100 }
    $avg=0;$min=0;$max=0;$jit=0
    if ($rtts.Count){
        $avg=[math]::Round((($rtts|Measure-Object -Average).Average),1)
        $min=[math]::Round((($rtts|Measure-Object -Minimum).Minimum),1)
        $max=[math]::Round((($rtts|Measure-Object -Maximum).Maximum),1)
        if ($rtts.Count -gt 1){ $m=($rtts|Measure-Object -Average).Average; $v=($rtts|ForEach-Object{[math]::Pow($_-$m,2)}|Measure-Object -Average).Average; $jit=[math]::Round([math]::Sqrt($v),1) }
    }
    [pscustomobject]@{ Target=$Target;Sent=$sent;Received=$recv;LossPct=$loss;AvgMs=$avg;MinMs=$min;MaxMs=$max;JitterMs=$jit;Reachable=($recv -gt 0) }
}

function Measure-Dns {
    param([string]$Name,[string]$Server)
    $sw=[System.Diagnostics.Stopwatch]::StartNew(); $ok=$false; $ips=@()
    try {
        if ($Server){ $res=Resolve-DnsName -Name $Name -Type A -Server $Server -DnsOnly -ErrorAction Stop }
        else        { $res=Resolve-DnsName -Name $Name -Type A -ErrorAction Stop }
        $ips=@($res|Where-Object {$_.IPAddress}|Select-Object -Expand IPAddress); $ok=($ips.Count -gt 0)
    } catch { $ok=$false }
    $sw.Stop()
    [pscustomobject]@{ Name=$Name;Server=$Server;Success=$ok;Ms=[math]::Round($sw.Elapsed.TotalMilliseconds,0);IPs=$ips }
}

function Test-PingSize {
    param([string]$Target,[int]$Size,$Opt)
    try { $b=New-Object byte[] $Size; $r=(New-Object System.Net.NetworkInformation.Ping).Send($Target,1500,$b,$Opt); return ($r.Status -eq 'Success') } catch { return $false }
}

function Test-TcpPort {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 2500)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $ok) { try { $client.Close() } catch {}; return [pscustomobject]@{ Success=$false; Ms=$TimeoutMs } }
        $client.EndConnect($iar)
        $ok2 = $client.Connected
        try { $client.Close() } catch {}
        return [pscustomobject]@{ Success=[bool]$ok2; Ms=0 }
    } catch {
        try { if ($client) { $client.Close() } } catch {}
        return [pscustomobject]@{ Success=$false; Ms=-1 }
    }
}

function Test-TcpTimed {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 2500)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Test-TcpPort -Target $Target -Port $Port -TimeoutMs $TimeoutMs
    $sw.Stop()
    $r.Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
    return $r
}

function Get-AddressKind {
    param([string]$Ip)
    if (-not $Ip) { return 'Unknown' }
    if ($Ip -like '169.254.*') { return 'APIPA' }
    if ($Ip -like '127.*') { return 'Loopback' }
    if ($Ip -match '^10\.' -or $Ip -match '^192\.168\.' -or $Ip -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.') { return 'Private' }
    if ($Ip -match '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.') { return 'CGNAT' }
    return 'Public'
}

function Test-IsEthernetAdapter {
    param($Adapter)
    if (-not $Adapter) { return $false }
    $pm = [string]$Adapter.PhysicalMediaType
    $mt = [string]$Adapter.MediaType
    $desc = [string]$Adapter.InterfaceDescription
    $name = [string]$Adapter.Name
    if ($pm -match '802\.3|Ethernet|Wired') { return $true }
    if ($mt -eq '802.3') { return $true }
    if ($desc -match 'Ethernet|GbE|Gigabit|PCIe.*NIC' -and $desc -notmatch 'Wireless|Wi-?Fi|802\.11|Virtual|VPN|Hyper-V|Bluetooth') { return $true }
    if ($name -match 'Ethernet' -and $desc -notmatch 'Wireless|Wi-?Fi|Virtual|VPN') { return $true }
    return $false
}

function Test-IsWifiAdapter {
    param($Adapter)
    if (-not $Adapter) { return $false }
    $pm = [string]$Adapter.PhysicalMediaType
    $desc = [string]$Adapter.InterfaceDescription
    $name = [string]$Adapter.Name
    if ($pm -match '802\.11|Native 802.11|Wireless') { return $true }
    if ($desc -match 'Wireless|Wi-?Fi|802\.11|WLAN|Centrino|Atheros.*Wireless') { return $true }
    if ($name -match 'Wi-?Fi|Wireless') { return $true }
    return $false
}

function Test-IsVirtualAdapter {
    param($Adapter)
    if (-not $Adapter) { return $false }
    $blob = "$($Adapter.InterfaceDescription) $($Adapter.Name) $($Adapter.DriverDescription)"
    return [bool]($blob -match 'VPN|TAP|TUN|WireGuard|Wintun|OpenVPN|WAN Miniport|ZeroTier|Tailscale|Hyper-V|vEthernet|VirtualBox|VMware|Pseudo|Bluetooth|Microsoft Wi-Fi Direct|Microsoft Hosted Network|Kdnic|Debug')
}

function Get-LeaseText {
    param($CimLease, $IpObj)
    if ($IpObj -and $IpObj.ValidLifetime) {
        try {
            $ts = [timespan]$IpObj.ValidLifetime
            if ($ts.TotalDays -gt 3650) { return 'does not expire' }
            $exp = (Get-Date) + $ts
            return $exp.ToString('yyyy-MM-dd HH:mm')
        } catch {}
    }
    if ($CimLease) {
        try {
            if ($CimLease -is [datetime]) { return $CimLease.ToString('yyyy-MM-dd HH:mm') }
            return ([Management.ManagementDateTimeConverter]::ToDateTime($CimLease)).ToString('yyyy-MM-dd HH:mm')
        } catch {}
    }
    return ''
}

# ------------------------------------------------------------------------------
# Step-by-step playbooks (everyday language, Windows 10/11 clicks)
# ------------------------------------------------------------------------------
function Get-Playbook {
    param([string]$Id)
    switch ($Id) {
        'PlugCable' { [pscustomobject]@{ Title='Plug in a network cable (most reliable fix)'; Steps=@(
            'Look at the side or back of this computer for a wide rectangular hole. It is bigger than a phone headset jack and usually has an icon that looks like three squares connected by lines.'
            'Take an Ethernet cable (the chunky cable that clicks in) and push it in until it clicks. Plug the other end into your internet box / router, in any LAN port (not the port labelled WAN/Internet unless that is the only one).'
            'On the router, a light next to that port should turn on. Wait about 15 seconds.'
            'On the computer, click the network icon at the bottom-right of the screen. You should see "Ethernet" as connected. A cable is steadier than Wi-Fi for video calls, games, and large downloads.'
        )} }
        'ToggleWifi' { [pscustomobject]@{ Title='Turn Wi-Fi off and back on'; Steps=@(
            'Click the network / Wi-Fi icon at the bottom-right corner of the screen (near the clock).'
            'Click the Wi-Fi button so it turns off. Wait 10 seconds.'
            'Click it again so it turns on. Wait until it reconnects to your home network.'
            'If a list of networks appears, click yours and choose Connect.'
        )} }
        'AirplaneOff' { [pscustomobject]@{ Title='Turn off Airplane mode'; Steps=@(
            'Click the network icon at the bottom-right of the screen.'
            'If Airplane mode is on (it may look highlighted), click it so it turns off.'
            'Turn Wi-Fi back on if it stayed off, then reconnect to your network.'
        )} }
        'EnableAdapter' { [pscustomobject]@{ Title='Turn the network adapter back on'; Steps=@(
            'Right-click the Start button (Windows logo, bottom-left) and choose Network Connections. Or open Settings > Network & internet > Advanced network settings.'
            'Click More network adapter options (on Windows 11) so you see a list of adapters.'
            'If Ethernet or Wi-Fi is greyed out, right-click it and choose Enable.'
            'Wait 15 seconds and see if a connection appears.'
        )} }
        'RestartRouter' { [pscustomobject]@{ Title='Restart the internet box (router / modem)'; Steps=@(
            'Find the box your internet company gave you (often with lights on the front). If you have two boxes (a modem and a Wi-Fi router), do both.'
            'Unplug the power cord from the back of the box (do not just press a button). Wait a full 30 seconds.'
            'Plug the power back in. Wait 2 full minutes until the lights settle (internet/WAN light should be solid, not frantically blinking).'
            'On this computer, turn Wi-Fi off and on once more, or unplug and replug the network cable.'
        )} }
        'EnableDhcp' { [pscustomobject]@{ Title='Let Windows get an address automatically'; Steps=@(
            'Open Settings (the gear). Go to Network & internet.'
            'Click Wi-Fi (or Ethernet if you are using a cable), then click your network name (or "Hardware properties").'
            'Next to IP assignment, click Edit. Choose Automatic (DHCP) and save. Do the same for DNS if it is set to Manual and you are not sure why.'
            'Turn the connection off and on. Windows should receive a proper address from your router.'
        )} }
        'SwitchDns' { [pscustomobject]@{ Title='Change DNS so website names load faster'; Steps=@(
            'Open Settings > Network & internet > Wi-Fi (or Ethernet) > your network > Hardware properties.'
            'Next to DNS server assignment, click Edit.'
            'Choose Manual. Turn IPv4 On. For Preferred DNS, type the address from the step title above (for example 9.9.9.9 or 1.1.1.1). For Alternate DNS type 8.8.8.8. Save.'
            'This does not change your internet company. It only changes the phone-book used to look up website names, which is often why pages feel slow to start.'
        )} }
        'Use5GHz' { [pscustomobject]@{ Title='Switch to the faster, less crowded Wi-Fi'; Steps=@(
            'Click the Wi-Fi icon at the bottom-right and look at the network list.'
            'If you see a second name like YourNetwork-5G, YourNetwork_5GHz, or the same name twice, pick the 5 GHz one. The 2.4 GHz name is the crowded "old" band.'
            'If you only see one name, open your router''s app or the sticker on the box and see whether 5 GHz is turned on. Many boxes ship with both; phones often join 2.4 GHz by habit.'
            'Standing closer to the box helps 5 GHz. Thick walls and distance work better on 2.4 GHz but it is slower and noisier.'
        )} }
        'RouterChannel' { [pscustomobject]@{ Title='Pick a clearer Wi-Fi channel on the router'; Steps=@(
            'This is done on the internet box, not on the PC. Open a browser and try http://192.168.1.1 or http://192.168.0.1 or the address printed on the sticker under the box. Log in with the sticker password.'
            'Find Wireless / Wi-Fi / 2.4 GHz settings. Set Channel to 1, 6, or 11 (not Auto if Auto keeps picking a crowded one). Save / Apply.'
            'Wait a minute. Reconnect this computer to Wi-Fi.'
        )} }
        'ForgetNetwork' { [pscustomobject]@{ Title='Forget the Wi-Fi and join it again'; Steps=@(
            'Open Settings > Network & internet > Wi-Fi > Manage known networks.'
            'Click your network name, then Forget.'
            'Go back, click the Wi-Fi icon, select the network, and Connect. Enter the Wi-Fi password from the sticker or the person who set it up.'
        )} }
        'DisablePowerSaving' { [pscustomobject]@{ Title='Stop Windows from putting the network to sleep'; Steps=@(
            'Right-click Start > Device Manager. Open Network adapters. Double-click your Wi-Fi or Ethernet adapter.'
            'Open the Power Management tab. Uncheck "Allow the computer to turn off this device to save power". Click OK.'
            'This stops random drops when the PC thinks it is idle.'
        )} }
        'DisableProxy' { [pscustomobject]@{ Title='Turn off a leftover proxy'; Steps=@(
            'Open Settings > Network & internet > Proxy.'
            'Turn off "Use a proxy server" unless your workplace told you to use one.'
            'Also turn off any automatic setup script you do not recognise. Then try a website again.'
        )} }
        'FixClock' { [pscustomobject]@{ Title='Fix the computer clock (needed for secure websites)'; Steps=@(
            'Right-click the time in the bottom-right corner and choose Adjust date and time.'
            'Turn on "Set time automatically" and "Set time zone automatically".'
            'Click Sync now. Secure sites (https) fail when the clock is more than a few minutes wrong.'
        )} }
        'DoubleNat' { [pscustomobject]@{ Title='Simplify two internet boxes stacked together'; Steps=@(
            'You currently have more than one box sharing the connection (two "private" networks in a row). That confuses games, video calls, and some smart devices.'
            'Best: plug this computer (or your main Wi-Fi box) into the box that actually has the internet company''s cable/fiber, and use only one Wi-Fi box.'
            'If you must keep two boxes, log into the extra box and look for Access Point / AP / Bridge mode (not Router mode). That stops the double sharing.'
            'If you cannot change this (apartment / office), use a cable to the main box when you need a stable connection.'
        )} }
        'CallIsp' { [pscustomobject]@{ Title='Check with your internet company'; Steps=@(
            'If this computer is healthy and the problem starts after your home box, the delay or outage is on the provider''s side.'
            'Reboot their box once (unplug 30 seconds). If it is still bad, call them and say: the home network looks fine, but the path after the first hop is slow or dead.'
            'Ask whether there is an outage, a line fault, or CGNAT (shared public address) if you need inbound connections / some games.'
        )} }
        'StartServices' { [pscustomobject]@{ Title='Turn Windows networking services back on'; Steps=@(
            'Right-click Start and choose Terminal (Admin) or Windows PowerShell (Admin). Agree to the prompt.'
            'Type this line and press Enter:  net start dhcp'
            'Then:  net start dnscache'
            'Then:  net start WlanSvc'
            'Restart the PC if a service refuses to start. These are the built-in helpers that request an address, look up names, and run Wi-Fi.'
        )} }
        'RebootPc' { [pscustomobject]@{ Title='Restart this computer'; Steps=@(
            'Save your work. Click Start > Power > Restart (not Shut down on some PCs, Restart is cleaner).'
            'After sign-in, wait 30 seconds for Wi-Fi or Ethernet to come back, then try a website.'
        )} }
        'UpdateDriver' { [pscustomobject]@{ Title='Update the network driver'; Steps=@(
            'Open Settings > Windows Update > Check for updates, including Optional / Advanced options driver updates.'
            'On an ASUS / Dell / HP / Lenovo PC, also use the manufacturer''s support app or drivers page for the Wi-Fi/Ethernet adapter.'
            'Very old drivers are a common cause of random disconnects and slow Wi-Fi.'
        )} }
        'IpConflict' { [pscustomobject]@{ Title='Stop two devices using the same address'; Steps=@(
            'On this PC, set IP assignment back to Automatic (DHCP) as in the "get an address automatically" steps.'
            'Restart the router so it hands out fresh addresses to phones, TVs, and PCs.'
            'If you (or someone) set a manual address like 192.168.1.50 on this PC, pick a different one or go back to Automatic so it cannot clash.'
        )} }
        default { $null }
    }
}

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------
try { $Host.UI.RawUI.WindowTitle = 'Net Doctor' } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Clear-Host
Write-C ""
Write-Rule 'Cyan'
Write-C ""
Write-C "      _   _      _          ____             _                     " 'Cyan'
Write-C "     | \ | | ___| |_       |  _ \  ___   ___| |_ ___  _ __         " 'Cyan'
Write-C "     |  \| |/ _ \ __|      | | | |/ _ \ / __| __/ _ \| '__|        " 'Cyan'
Write-C "     | |\  |  __/ |_       | |_| | (_) | (__| || (_) | |           " 'Cyan'
Write-C "     |_| \_|\___|\__|      |____/ \___/ \___|\__\___/|_|           " 'Cyan'
Write-C ""
Write-C "                    NET  DOCTOR   v$script:AppVersion                        " 'White'
Write-C "           Full checkup of every connection (wired + Wi-Fi)            " 'DarkGray'
Write-C ""
Write-Rule 'Cyan'
Write-C ""

$startTime = Get-Date
$modeText = if ($DryRun -and $Fix) { 'DIAGNOSE + FIX PREVIEW (dry run)' } elseif ($DeepFix) { 'DIAGNOSE + DEEP AUTO-FIX' } elseif ($Fix) { 'DIAGNOSE + AUTO-FIX' } else { 'DIAGNOSE ONLY' }
Write-KV "Version" $script:AppVersion
Write-KV "Scan started" ($startTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-KV "Mode" $modeText $(if($Fix){'Yellow'}else{'White'})
Write-KV "Elevation" ($(if ($isAdmin) {'Administrator'} else {'Standard user'})) $(if($isAdmin){'Green'}else{'Yellow'})
if ($Quick) { Write-KV "Speed" "Quick (slow tests skipped)" 'Yellow' }
else { Write-KV "Scope" "Full engineer checkup (about 1-2 minutes)" 'White' }
Write-C ""
Write-Wrap "What this does: Net Doctor walks the path from this computer, through the cable or Wi-Fi, through your home box, and out to the internet. Then it explains the result in plain language and tells you exactly what to click." 'DarkGray'

$script:PrimaryIfIndex = $null
$script:PrimaryIfAlias = $null
$script:BestPublicDns  = @()
$script:GwList = @(); $script:DnsList = @(); $script:InternetUp = $false
$script:Hops = New-Object System.Collections.Generic.List[object]

# ==============================================================================
# 1. SYSTEM
# ==============================================================================
Write-Section "This computer"
try {
    $os=Get-CimInstance Win32_OperatingSystem; $cs=Get-CimInstance Win32_ComputerSystem
    $uptime=(Get-Date)-$os.LastBootUpTime
    Write-KV "Computer name" $env:COMPUTERNAME
    Write-KV "User" "$env:USERDOMAIN\$env:USERNAME"
    Write-KV "Windows" "$($os.Caption) ($($os.Version))"
    Write-KV "Model" ("{0} {1}" -f $cs.Manufacturer,$cs.Model)
    Write-KV "Uptime" ("{0}d {1}h {2}m" -f $uptime.Days,$uptime.Hours,$uptime.Minutes)
    Set-Fact 'Computer' $env:COMPUTERNAME
    Set-Fact 'Model' ("{0} {1}" -f $cs.Manufacturer,$cs.Model)
    Set-Fact 'UptimeDays' $uptime.TotalDays
    if ($uptime.TotalDays -gt 14){
        Add-Finding Info 'System' ("Up for {0} days." -f [int]$uptime.TotalDays) "A restart occasionally clears stuck network/driver glitches." `
            -PlainWhat "This computer has not been fully restarted in a long time." `
            -PlainWhy "Windows networking can get stuck after weeks of sleep and wake. A restart is a fair first try when nothing else makes sense." `
            -Playbooks @('RebootPc') -Priority 15
    }
} catch { Write-Status Warning "Could not read full system info." }

# Airplane / radio
$airplane = $false
try {
    $radio = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState' -ErrorAction SilentlyContinue
    if ($radio -and $radio.PSObject.Properties['SystemRadioState'] -and [int]$radio.SystemRadioState -eq 1) { $airplane = $true }
} catch {}
try {
    if (-not $airplane) {
        $airProf = Get-NetConnectionProfile -ErrorAction SilentlyContinue
    }
} catch {}
Write-KV "Airplane mode" ($(if($airplane){'ON'}else{'Off'})) $(if($airplane){'Red'}else{'Green'})
Set-Fact 'Airplane' $airplane
if ($airplane) {
    Add-Finding Critical 'System' "Airplane mode is ON - radios are disabled." "Turn off Airplane mode, then enable Wi-Fi." `
        -PlainWhat "Airplane mode is switched on, so this computer has turned its wireless off on purpose." `
        -PlainWhy "That is the same switch used on a plane. Nothing wireless can connect until you turn it off." `
        -Playbooks @('AirplaneOff') -Priority 100
}

# Power plan
try {
    $scheme = (powercfg /getactivescheme 2>$null)
    if ($scheme -match '\((.+)\)') {
        $plan = $Matches[1]
        Write-KV "Power plan" $plan
        if ($plan -match 'Power saver|Saver') {
            Add-Finding Info 'System' "Power saver plan is active." "Power saver can slow or sleep the Wi-Fi adapter." `
                -PlainWhat "The laptop is in Power saver." `
                -PlainWhy "Windows may throttle or sleep the Wi-Fi hardware to save battery, which feels like a flaky internet." `
                -Priority 12
        }
    }
} catch {}

# ==============================================================================
# 2. ALL CONNECTIONS
# ==============================================================================
Write-Section "Every network connection (wired, Wi-Fi, virtual)"
$activeAdapters=@(); $allAdapters=@(); $ethAdapters=@(); $wifiAdapters=@(); $virtAdapters=@(); $otherAdapters=@()
$upCount=0; $ethUp=$false; $ethPresent=$false; $ethDisconnected=$false; $wifiPresent=$false; $wifiUp=$false
try {
    $allAdapters = @(Get-NetAdapter | Sort-Object MacAddress, Name)
    foreach ($a in $allAdapters) {
        $isUp = ($a.Status -eq 'Up')
        if ($isUp) { $upCount++; $activeAdapters += $a }
        if (Test-IsVirtualAdapter $a) { $virtAdapters += $a }
        elseif (Test-IsEthernetAdapter $a) { $ethAdapters += $a; $ethPresent=$true; if ($isUp){ $ethUp=$true } elseif ($a.Status -eq 'Disconnected'){ $ethDisconnected=$true } }
        elseif (Test-IsWifiAdapter $a) { $wifiAdapters += $a; $wifiPresent=$true; if ($isUp){ $wifiUp=$true } }
        else { $otherAdapters += $a }
    }

    function Write-AdapterGroup {
        param([string]$Heading, $List)
        Write-C ""
        Write-C "  $Heading" 'White'
        if (-not $List -or $List.Count -eq 0) { Write-C "    (none Windows can see)" 'DarkGray'; return }
        foreach ($a in $List) {
            $isUp = ($a.Status -eq 'Up')
            $col = if ($isUp) { 'Green' } elseif ($a.Status -eq 'Disconnected') { 'Yellow' } elseif ($a.Status -eq 'Disabled') { 'Red' } else { 'DarkGray' }
            $speed = if ($a.LinkSpeed) { [string]$a.LinkSpeed } else { '-' }
            $note = ''
            if ($a.Status -eq 'Disconnected' -and (Test-IsEthernetAdapter $a)) { $note = '  <- nothing plugged in (or the other end is off)' }
            elseif ($a.Status -eq 'Disabled') { $note = '  <- turned off in Windows' }
            $n = $a.Name; if ($n.Length -gt 20) { $n = $n.Substring(0,20) }
            Write-C ("    {0,-20} {1,-14} {2,-12} {3}{4}" -f $n, $a.Status, $speed, $a.InterfaceDescription, $note) $col
            if ($a.MacAddress) {
                $metTxt = ''
                try {
                    $ifiM = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    if ($ifiM) { $metTxt = "metric $($ifiM.InterfaceMetric)" }
                } catch {}
                Write-C ("      MAC {0}   ifIndex {1}   {2}" -f $a.MacAddress, $a.ifIndex, $metTxt) 'DarkGray'
            }
        }
    }

    Write-AdapterGroup 'WIRED  (Ethernet cable)' $ethAdapters
    Write-AdapterGroup 'WI-FI  (wireless)' $wifiAdapters
    Write-AdapterGroup 'VIRTUAL / VPN / OTHER' (@($virtAdapters) + @($otherAdapters))

    Write-C ""
    Write-KV "Active (Up) adapters" "$upCount"
    Set-Fact 'EthPresent' $ethPresent; Set-Fact 'EthUp' $ethUp; Set-Fact 'EthDisconnected' $ethDisconnected
    Set-Fact 'WifiPresent' $wifiPresent; Set-Fact 'WifiUp' $wifiUp; Set-Fact 'UpCount' $upCount

    if ($upCount -eq 0) {
        Add-Finding Critical 'Adapter' "No active (Up) network adapter." "Enable the adapter; plug in a cable; turn off Airplane mode; turn Wi-Fi on." `
            -PlainWhat "Windows does not have any working network plug or Wi-Fi currently turned on." `
            -PlainWhy "Until something is Up, this PC cannot talk to a router or the internet." `
            -Playbooks @('AirplaneOff','EnableAdapter','PlugCable','ToggleWifi') -Priority 100
        Write-Status Critical "No connected network adapter."
    } else {
        Add-Finding Good 'Adapter' "$upCount active adapter(s)."
        if ($ethPresent -and $ethDisconnected -and $wifiUp) {
            Add-Finding Info 'Adapter' "Ethernet port is present but nothing is plugged in (using Wi-Fi)." "A cable is more stable than Wi-Fi. Plug in if you have a spare Ethernet cable." `
                -PlainWhat "This computer has a cable port, but it is empty. You are on Wi-Fi only." `
                -PlainWhy "A cable does not share the air with neighbours and usually fixes 'Wi-Fi is weird' problems immediately." `
                -Playbooks @('PlugCable') -Priority 25
        }
        if ($ethPresent -and -not $ethUp -and -not $wifiUp) {
            Add-Finding Critical 'Adapter' "Ethernet is not linked and Wi-Fi is not connected." "Plug in a cable or connect to Wi-Fi." `
                -PlainWhat "Neither a cable nor Wi-Fi is actually connected." `
                -Playbooks @('PlugCable','ToggleWifi','EnableAdapter') -Priority 98
        }
    }

    foreach ($a in $activeAdapters) {
        $st = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
        if ($st) {
            $errs = 0; $disc = 0
            try { $errs = [int64]$st.ReceivedPacketErrors + [int64]$st.OutboundPacketErrors } catch {}
            try { $disc = [int64]$st.ReceivedDiscardedPackets + [int64]$st.OutboundDiscardedPackets } catch {}
            if ($errs -gt 100 -or $disc -gt 1000) {
                Add-Finding Warning 'Adapter' ("Adapter '{0}' errors={1} discards={2}." -f $a.Name,$errs,$disc) "Bad cable, flaky Wi-Fi air, or a driver issue." `
                    -PlainWhat ("The {0} connection is dropping or mangling a lot of data." -f $a.Name) `
                    -PlainWhy "That usually means a damaged cable, a loose plug, or messy Wi-Fi in the air." `
                    -Playbooks @('PlugCable','ToggleWifi','UpdateDriver') -Priority 55
            }
        }
        try {
            if ($a.DriverDate) {
                $dd = [datetime]$a.DriverDate; $ageY = [math]::Round(((Get-Date)-$dd).TotalDays/365,1)
                Write-KV ("Driver: "+$a.Name) ("{0} ({1}, {2}y old)" -f $a.DriverVersion,$dd.ToString('yyyy-MM-dd'),$ageY)
                if ($ageY -gt 4) {
                    Add-Finding Info 'Adapter' ("NIC driver for '$($a.Name)' is ~$ageY years old.") "Update the network driver from Windows Update or the PC maker." `
                        -PlainWhat "The software that runs your network card is several years old." `
                        -Playbooks @('UpdateDriver') -Priority 18
                }
            }
        } catch {}
        try {
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
            if ($pm -and $pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
                Add-Finding Warning 'Adapter' ("Windows may power off '$($a.Name)' to save energy.") "This causes random Wi-Fi/LAN drops. Disable power management on the adapter." `
                    -PlainWhat "Windows is allowed to put the network hardware to sleep to save power." `
                    -PlainWhy "That is a very common reason the internet 'just dies' after the laptop sits still, then comes back." `
                    -Playbooks @('DisablePowerSaving') -Priority 40
                $adapterName = $a.Name
                Add-Remediation 'Adapter' "Adapter power-saving can drop the link" ("Disable power management on '$adapterName'") ({ Set-NetAdapterPowerManagement -Name $adapterName -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop }.GetNewClosure()) ("Set-NetAdapterPowerManagement -Name '$adapterName' -AllowComputerToTurnOffDevice Enabled")
            }
        } catch {}
        try {
            $binds = Get-NetAdapterBinding -Name $a.Name -ErrorAction SilentlyContinue
            $ip4on = $binds | Where-Object { $_.ComponentID -eq 'ms_tcpip' }
            if ($ip4on -and -not $ip4on.Enabled) {
                Add-Finding Critical 'Adapter' ("IPv4 is disabled on '{0}'." -f $a.Name) "Enable Internet Protocol Version 4 (TCP/IPv4) on that adapter." `
                    -PlainWhat "The usual internet language (IPv4) is switched off on this connection." `
                    -PlainWhy "Almost every home network still needs IPv4. With it off, pages will not load even if Wi-Fi looks connected." `
                    -Priority 95
            }
        } catch {}
    }
} catch { Write-Status Warning "Unable to enumerate adapters." }

# ==============================================================================
# 3. WIRED ETHERNET
# ==============================================================================
Write-Section "Wired Ethernet (cable)"
if (-not $ethPresent) {
    Write-Status Info "Windows does not see an Ethernet (cable) adapter on this PC."
    Write-Wrap "Some slim laptops only have Wi-Fi, or need a USB-C to Ethernet dongle. If you have a dongle, plug it in and run Net Doctor again." 'DarkGray'
    Add-Finding Info 'Ethernet' "No Ethernet adapter detected." "Use a USB-C Ethernet adapter if you want a wired test." `
        -PlainWhat "This PC does not appear to have a built-in cable port that Windows can see." `
        -Priority 5
} else {
    foreach ($a in $ethAdapters) {
        Write-C ""
        Write-KV "Adapter" $a.Name 'White'
        Write-KV "Hardware" $a.InterfaceDescription
        Write-KV "Status" ([string]$a.Status) $(if($a.Status -eq 'Up'){'Green'}elseif($a.Status -eq 'Disabled'){'Red'}else{'Yellow'})
        Write-KV "Link speed" ($(if($a.LinkSpeed){$a.LinkSpeed}else{'(no link)'}))
        $duplex = ''
        try { if ($null -ne $a.FullDuplex) { $duplex = $(if($a.FullDuplex){'Full duplex'}else{'Half duplex'}) } } catch {}
        try {
            $spdProp = Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Speed.*Duplex|Speed & Duplex' } | Select-Object -First 1
            if ($spdProp) { Write-KV "Speed/Duplex setting" ([string]$spdProp.DisplayValue) }
        } catch {}
        if ($duplex) { Write-KV "Duplex" $duplex $(if($duplex -match 'Half'){'Yellow'}else{'White'}) }
        try {
            $eee = Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Energy Efficient|Green Ethernet|EEE' -or $_.RegistryKeyword -match 'EEE|EnableGreenEthernet' } | Select-Object -First 1
            if ($eee) { Write-KV "Energy-efficient Ethernet" ([string]$eee.DisplayValue) }
        } catch {}

        if ($a.Status -eq 'Disabled') {
            Add-Finding Warning 'Ethernet' ("Ethernet adapter '{0}' is Disabled." -f $a.Name) "Enable it in Network Connections." `
                -PlainWhat "The cable connection is switched off in Windows." `
                -Playbooks @('EnableAdapter') -Priority 70
            $nm=$a.Name
            Add-Remediation 'Ethernet' "Ethernet adapter is disabled" ("Enable adapter '$nm'") ({ Enable-NetAdapter -Name $nm -Confirm:$false -ErrorAction Stop }.GetNewClosure()) ("Disable-NetAdapter -Name '$nm' -Confirm:`$false")
        } elseif ($a.Status -eq 'Disconnected') {
            Add-Finding Warning 'Ethernet' ("Ethernet '{0}' has no link - cable unplugged, dead cable, or switch/router port off." -f $a.Name) "Seat the cable until it clicks; try another cable and another port on the router." `
                -PlainWhat "The cable port is empty, or the cable is not making a connection." `
                -PlainWhy "Until that port shows 'connected', this PC cannot use wired internet. Try a different cable; they fail more often than people expect." `
                -Playbooks @('PlugCable') -Priority 45
        } elseif ($a.Status -eq 'Up') {
            Add-Finding Good 'Ethernet' ("Ethernet '{0}' is linked at {1}." -f $a.Name, $a.LinkSpeed)
            $spd = [string]$a.LinkSpeed
            if ($spd -match '^(10|100) Mbps') {
                Add-Finding Warning 'Ethernet' ("Ethernet '{0}' linked at only {1}." -f $a.Name, $spd) "Likely an old/damaged cable, a 10/100 port, or a failed auto-negotiate. Use a Cat5e/Cat6 cable in a gigabit port." `
                    -PlainWhat "The cable is working, but only at old, slow speed." `
                    -PlainWhy "A gigabit cable and port should say 1 Gbps. 10 or 100 Mbps is a dusty cable, a bent pin, or a cheap port." `
                    -Playbooks @('PlugCable') -Priority 48
            }
            if ($duplex -match 'Half') {
                Add-Finding Warning 'Ethernet' ("Ethernet '{0}' is half duplex." -f $a.Name) "Force both sides to auto-negotiate or 1 Gbps full duplex. Half duplex causes collisions and slowness." `
                    -PlainWhat "The cable connection is running in an old 'one direction at a time' mode." `
                    -Priority 50
            }
        }
    }
    if ($ethUp -and $wifiUp) {
        Write-C ""
        Write-Wrap "Both a cable and Wi-Fi are connected. Windows will pick one as the way out to the internet (usually the one with the lower 'metric'). We check that in the address section." 'DarkGray'
        Add-Finding Info 'Ethernet' "Both Ethernet and Wi-Fi are Up." "If things are odd, disconnect Wi-Fi and test cable-only (or the reverse) to see which path is bad." `
            -PlainWhat "This PC is using both a cable and Wi-Fi at the same time." `
            -PlainWhy "Windows might send traffic over the worse one. For a clean test, turn Wi-Fi off and use only the cable." `
            -Priority 22
    }
}

# ==============================================================================
# 4. WI-FI
# ==============================================================================
Write-Section "Wi-Fi (wireless)"
$wifiConnected=$false; $myChannel=0; $myBand=''; $ssid=''; $wifiAuth=''; $wifiBssid=''
try {
    $wlan = netsh wlan show interfaces 2>$null
    $wlanLines = @($wlan)
    if ($LASTEXITCODE -eq 0 -and ($wlan -match 'SSID')) {
        $state = Get-NetshValue $wlanLines 'State'
        if ($state -match 'connected') {
            $wifiConnected = $true
            $ssid     = Get-NetshValue $wlanLines 'SSID'
            $myBand   = Get-NetshValue $wlanLines 'Band'
            $chan     = Get-NetshValue $wlanLines 'Channel'
            $radio    = Get-NetshValue $wlanLines 'Radio type'
            $sigStr   = Get-NetshValue $wlanLines 'Signal'
            $rssiStr  = Get-NetshValue $wlanLines 'Rssi'
            $rx       = Get-NetshValue $wlanLines 'Receive rate (Mbps)'
            $tx       = Get-NetshValue $wlanLines 'Transmit rate (Mbps)'
            $wifiAuth = Get-NetshValue $wlanLines 'Authentication'
            $cipher   = Get-NetshValue $wlanLines 'Cipher'
            $wifiBssid= Get-NetshValue $wlanLines 'BSSID'
            $profile  = Get-NetshValue $wlanLines 'Profile'
            Write-KV "Network name (SSID)" $ssid
            Write-KV "Band" $myBand
            Write-KV "Channel" $chan
            Write-KV "Radio type" $radio
            Write-KV "Sign-in / encryption" ("{0} / {1}" -f $(if($wifiAuth){$wifiAuth}else{'?'}), $(if($cipher){$cipher}else{'?'}))
            Write-KV "Signal" $sigStr
            if ($rssiStr) { Write-KV "RSSI" "$rssiStr dBm" }
            Write-KV "Link rate Rx / Tx" "$rx / $tx Mbps"
            if ($wifiBssid) { Write-KV "Access point (BSSID)" $wifiBssid 'DarkGray' }
            if ($profile) { Write-KV "Saved profile" $profile }

            Set-Fact 'Ssid' $ssid; Set-Fact 'Band' $myBand; Set-Fact 'WifiAuth' $wifiAuth
            $signalPct=0; [int]::TryParse(($sigStr -replace '[^\d]',''),[ref]$signalPct) | Out-Null
            $rssi=0; [int]::TryParse(($rssiStr -replace '[^\-\d]',''),[ref]$rssi) | Out-Null
            [int]::TryParse(($chan -replace '[^\d]',''),[ref]$myChannel) | Out-Null
            Set-Fact 'Channel' $myChannel; Set-Fact 'Rssi' $rssi; Set-Fact 'SignalPct' $signalPct

            if ($rssi -ne 0) {
                if ($rssi -le -80) {
                    Add-Finding Critical 'Wi-Fi' ("Very weak Wi-Fi signal (RSSI $rssi dBm).") "Move closer, remove walls/microwaves, or use a cable / 5 GHz." `
                        -PlainWhat "The Wi-Fi signal is extremely weak  - like hearing someone whisper through several walls." `
                        -PlainWhy "The computer is barely holding the conversation with the box. Pages stall, video stutters, and calls drop." `
                        -Playbooks @('PlugCable','Use5GHz') -Priority 80
                } elseif ($rssi -le -70) {
                    Add-Finding Warning 'Wi-Fi' ("Weak Wi-Fi signal (RSSI $rssi dBm).") "Move closer or use 5 GHz / Ethernet." `
                        -PlainWhat "Wi-Fi is a bit far away or blocked." `
                        -Playbooks @('PlugCable','Use5GHz') -Priority 52
                } else {
                    Add-Finding Good 'Wi-Fi' ("Good Wi-Fi signal (RSSI $rssi dBm).")
                }
            } elseif ($signalPct -gt 0) {
                if ($signalPct -lt 40) {
                    Add-Finding Warning 'Wi-Fi' ("Low Wi-Fi signal (${signalPct}%).") "Move closer or reduce interference." -Playbooks @('PlugCable','Use5GHz') -Priority 52
                } else { Add-Finding Good 'Wi-Fi' ("Wi-Fi signal ${signalPct}%.") }
            }

            if ($wifiAuth -match 'Open|WEP' -or $cipher -match '^WEP$') {
                Add-Finding Warning 'Wi-Fi' "Wi-Fi is using weak or no encryption ($wifiAuth)." "Use WPA2 or WPA3 with a password. Open/WEP networks are unsafe and often throttled." `
                    -PlainWhat "This Wi-Fi is unlocked or using very old protection." `
                    -PlainWhy "Anyone nearby can join or spy. Ask the owner to set a WPA2/WPA3 password." `
                    -Priority 42
            }

            if ($myBand -match '2\.4') {
                Set-Fact 'On24' $true
                if ($myChannel -and $myChannel -notin 1,6,11) {
                    Add-Finding Warning 'Wi-Fi' ("On 2.4 GHz channel $myChannel (overlapping).") "On the router, set 2.4 GHz to channel 1, 6, or 11." `
                        -PlainWhat "You are on the crowded 2.4 GHz Wi-Fi band, on a channel that overlaps the neighbours." `
                        -PlainWhy "2.4 GHz is the older, slower radio. Channels that are not 1, 6, or 11 talk over each other, like several conversations in the same small room." `
                        -Playbooks @('Use5GHz','RouterChannel','PlugCable') -Priority 35
                } else {
                    Add-Finding Info 'Wi-Fi' "Connected on 2.4 GHz." "If the box offers 5 GHz, use it for speed. Use a cable for the most stable link." `
                        -PlainWhat "You are on the older 2.4 GHz Wi-Fi band." `
                        -PlainWhy "It reaches farther through walls but is slower and shares the air with neighbours, Bluetooth, and microwaves." `
                        -Playbooks @('Use5GHz','PlugCable') -Priority 28
                }
            } elseif ($myBand -match '5|6') {
                Set-Fact 'On24' $false
                Add-Finding Good 'Wi-Fi' ("Connected on $myBand.")
            }
        } else {
            Write-Status Info "Wi-Fi hardware is present but not connected (you may be using a cable instead)."
            Set-Fact 'WifiPresent' $true
        }
    } else {
        Write-Status Info "No Wi-Fi interface reported by Windows."
    }
} catch { Write-Status Info "Wi-Fi details unavailable." }

$nearby5 = 0; $nearby24 = 0; $sameSsid5 = $false
if ($wifiPresent -and -not $Quick) {
    try {
        $nets = netsh wlan show networks mode=bssid 2>$null
        $block = ($nets -join "`n")
        $chans = @(); foreach ($m in ([regex]::Matches($block,'Channel\s*:\s*(\d+)'))) { $chans += [int]$m.Groups[1].Value }
        foreach ($c in $chans) { if ($c -gt 14) { $nearby5++ } else { $nearby24++ } }
        if ($ssid) {
            if ($block -match [regex]::Escape($ssid) -and $block -match '5\s*GHz|Channel\s*:\s*(3[6-9]|[4-9][0-9]|1[0-6][0-9])') { $sameSsid5 = $true }
        }
        if ($chans.Count) {
            $sameCh = @($chans | Where-Object { $_ -eq $myChannel }).Count
            $overlap = @($chans | Where-Object { $_ -le 14 -and $myChannel -le 14 -and [math]::Abs($_-$myChannel) -le 4 }).Count
            Write-KV "Nearby Wi-Fi networks" ("{0} total  ({1} on 2.4 GHz, {2} on 5 GHz)" -f $chans.Count, $nearby24, $nearby5)
            if ($wifiConnected) { Write-KV "On your channel" ("{0} same, {1} overlapping" -f $sameCh, $overlap) }
            Set-Fact 'Nearby5' $nearby5
            if ($wifiConnected -and $myBand -match '2\.4' -and $overlap -ge 4) {
                Add-Finding Warning 'Wi-Fi' ("$overlap nearby networks overlap your 2.4 GHz channel $myChannel.") "Switch to 5 GHz or channels 1/6/11." `
                    -PlainWhat "A lot of neighbouring Wi-Fi is shouting on the same channel you are using." `
                    -Playbooks @('Use5GHz','RouterChannel','PlugCable') -Priority 36
            } elseif ($wifiConnected -and $sameCh -ge 3) {
                Add-Finding Info 'Wi-Fi' ("$sameCh other networks share your channel.") "A channel change or 5 GHz may help." -Playbooks @('Use5GHz','RouterChannel') -Priority 20
            }
            if ($wifiConnected -and $myBand -match '2\.4' -and $nearby5 -gt 0) {
                Add-Finding Info 'Wi-Fi' "5 GHz Wi-Fi is in range, but this PC joined 2.4 GHz." "Join the 5 GHz name if you see one, or enable band steering on the router." `
                    -PlainWhat "A faster 5 GHz Wi-Fi is nearby, but this computer joined the slower 2.4 GHz one." `
                    -Playbooks @('Use5GHz') -Priority 33
            }
        }
    } catch {}
}

# ==============================================================================
# 5. WINDOWS NETWORK SERVICES + PROFILE
# ==============================================================================
Write-Section "Windows network services & status"
$svcMap = @(
    @{N='DHCP Client'; S='Dhcp'; Why='asks the router for an address'},
    @{N='DNS Client'; S='Dnscache'; Why='looks up website names'},
    @{N='Network Location Awareness'; S='NlaSvc'; Why='decides if you have internet'},
    @{N='Network List Service'; S='netprofm'; Why='keeps the list of networks'},
    @{N='WLAN AutoConfig'; S='WlanSvc'; Why='runs Wi-Fi'},
    @{N='Windows Connection Manager'; S='Wcmsvc'; Why='manages connections'}
)
$alreadyOnline = $false
try { $alreadyOnline = [bool]@(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Connectivity -eq 'Internet' }).Count } catch {}
$coreSvc = @('Dhcp','Dnscache'); if ($wifiPresent) { $coreSvc += 'WlanSvc' }
$stopped = @()
foreach ($item in $svcMap) {
    try {
        $svc = Get-Service -Name $item.S -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $col = if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-KV $item.N ("{0}  ({1})" -f $svc.Status, $item.Why) $col
        if ($svc.Status -ne 'Running') {
            $stopped += $item.N
            if ($item.S -eq 'WlanSvc' -and -not $wifiPresent) { continue }
            $svcName = $item.S
            if ($item.S -in $coreSvc) {
                Add-Finding Critical 'System' ("Service '$($item.N)' is $($svc.Status).") "Start the service. It $($item.Why)." `
                    -PlainWhat ("A built-in Windows helper ({0}) is not running." -f $item.N) `
                    -PlainWhy ("That helper {0}. Without it, networking misbehaves." -f $item.Why) `
                    -Playbooks @('StartServices','RebootPc') -Priority 90
                Add-Remediation 'System' ("Service $($item.N) is not running") ("Start service $svcName") ({ Start-Service -Name $svcName -ErrorAction Stop }.GetNewClosure()) ("Stop-Service -Name $svcName")
            } elseif ($alreadyOnline) {
                Add-Finding Info 'System' ("Service '$($item.N)' is $($svc.Status), but Windows already reports Internet.") "Optional: start $svcName if the task-bar icon misbehaves." `
                    -PlainWhat ("A background Windows helper ({0}) is not running, but the internet still looks up." -f $item.N) `
                    -Priority 8
            } else {
                Add-Finding Warning 'System' ("Service '$($item.N)' is $($svc.Status).") "Start the service. It $($item.Why)." `
                    -PlainWhat ("A Windows helper ({0}) is not running." -f $item.N) `
                    -PlainWhy ("That helper {0}." -f $item.Why) `
                    -Playbooks @('StartServices','RebootPc') -Priority 35
                Add-Remediation 'System' ("Service $($item.N) is not running") ("Start service $svcName") ({ Start-Service -Name $svcName -ErrorAction Stop }.GetNewClosure()) ("Stop-Service -Name $svcName")
            }
        }
    } catch {}
}
if (-not $stopped.Count) { Add-Finding Good 'System' "Core Windows network services are running." }

try {
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    if ($profiles) {
        foreach ($np in $profiles) {
            Write-KV ("Windows says ($($np.InterfaceAlias))") ("{0}  |  IPv4: {1}  IPv6: {2}" -f $np.NetworkCategory, $np.IPv4Connectivity, $np.IPv6Connectivity)
            Set-Fact 'NcsiV4' ([string]$np.IPv4Connectivity)
            Set-Fact 'NetCategory' ([string]$np.NetworkCategory)
            if ($np.IPv4Connectivity -eq 'Internet') { Add-Finding Good 'System' "Windows NCSI reports Internet on '$($np.InterfaceAlias)'." }
            elseif ($np.IPv4Connectivity -in @('LocalNetwork','Subnet')) {
                Add-Finding Warning 'System' ("Windows thinks '$($np.InterfaceAlias)' has no Internet (NCSI=$($np.IPv4Connectivity)).") "Local LAN only, captive portal, or NCSI probe blocked." `
                    -PlainWhat "The little globe/Wi-Fi icon may show 'No internet' even if some things work." `
                    -PlainWhy "Windows does its own tiny website check. If that check is blocked, the icon lies. We still test for real." `
                    -Priority 30
            } elseif ($np.IPv4Connectivity -in @('Disconnected','NoTraffic')) {
                Add-Finding Warning 'System' ("Windows reports no IPv4 traffic on '$($np.InterfaceAlias)' (NCSI=$($np.IPv4Connectivity)).") "Adapter is up but not passing IPv4 yet (DHCP delay, cable, or driver)." `
                    -Playbooks @('ToggleWifi','EnableDhcp','RestartRouter') -Priority 60
            }
        }
    }
} catch {}

# recent link / DHCP events
if (-not $Quick) {
    try {
        $ev = Get-WinEvent -FilterHashtable @{LogName='System'; Id=@(4198,4199,4200,1001,1003,1005,27,32); StartTime=(Get-Date).AddDays(-2)} -MaxEvents 30 -ErrorAction SilentlyContinue
        if ($ev) {
            $conf = @($ev | Where-Object { $_.Id -in 4198,4199 }).Count
            if ($conf -gt 0) {
                Add-Finding Warning 'IP' ("$conf IP address-conflict event(s) in the last 2 days.") "Another device used this IP. Use DHCP or a different static IP." `
                    -PlainWhat "Recently, two devices on your network argued over the same address." `
                    -PlainWhy "Like two houses with the same number, mail (data) goes to the wrong place until it is sorted out." `
                    -Playbooks @('IpConflict','EnableDhcp','RestartRouter') -Priority 40
            }
        }
    } catch {}
}

# ==============================================================================
# 6. IP CONFIGURATION
# ==============================================================================
Write-Section "Addresses (how this PC is identified)"
$gateways=@(); $dnsServers=@(); $hasIPv6Global=$false; $hasApipa=$false; $originPrimary=''
try {
    $cfgs = @(Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' -or $_.IPv4Address -or $_.IPv6Address })
    if (-not $cfgs) { $cfgs = @(Get-NetIPConfiguration | Where-Object { $_.IPv4Address -or $_.IPv6Address }) }
    foreach ($cfg in $cfgs) {
        $ipv4 = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
        $prefix = ($cfg.IPv4Address | Select-Object -First 1).PrefixLength
        $gw = ($cfg.IPv4DefaultGateway | Select-Object -First 1).NextHop
        $dns = @($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | Select-Object -Expand ServerAddresses)
        if (-not $script:PrimaryIfIndex -and ($gw -or $ipv4)) { $script:PrimaryIfIndex=$cfg.InterfaceIndex; $script:PrimaryIfAlias=$cfg.InterfaceAlias }
        $origin='Unknown'; $dhcpSrv=''; $leaseExp=''; $ip4o=$null
        try {
            $ip4o = Get-NetIPAddress -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $ipv4 } | Select-Object -First 1
            if (-not $ip4o) { $ip4o = Get-NetIPAddress -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if ($ipv4 -like '169.254.*') { $origin = 'APIPA (self-assigned  - DHCP failed)' }
            elseif ($ip4o) {
                if ($ip4o.PrefixOrigin -eq 'Dhcp') { $origin = 'DHCP (automatic from the router)' }
                elseif ($ip4o.PrefixOrigin -eq 'Manual') { $origin = 'Static / manual' }
                elseif ($ip4o.PrefixOrigin -eq 'WellKnown') { $origin = 'Well-known / automatic private' }
                else { $origin = [string]$ip4o.PrefixOrigin }
            }
            $nc = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($cfg.InterfaceIndex)" -ErrorAction SilentlyContinue
            if (-not $nc) { $nc = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "Index=$($cfg.InterfaceIndex)" -ErrorAction SilentlyContinue }
            if ($nc) {
                if ($nc.DHCPServer) { $dhcpSrv = [string]$nc.DHCPServer }
                $leaseExp = Get-LeaseText -CimLease $nc.DHCPLeaseExpires -IpObj $ip4o
            }
        } catch {}

        $kind = Get-AddressKind $ipv4
        Write-C ""
        Write-KV "Connection" $cfg.InterfaceAlias 'White'
        Write-KV "  IPv4 address" ($(if($ipv4){"$ipv4 /$prefix  [$kind]"}else{'(none)'})) $(if($kind -eq 'APIPA'){'Red'}elseif($ipv4){'Green'}else{'Yellow'})
        Write-KV "  How it got the address" $origin
        Write-KV "  Gateway (next box)" ($(if($gw){$gw}else{'(none)'})) $(if($gw){'White'}else{'Red'})
        Write-KV "  DNS (name lookup)" ($(if($dns){$dns -join ', '}else{'(none)'}))
        if ($dhcpSrv) { Write-KV "  DHCP server / lease" ("{0}  (until {1})" -f $dhcpSrv, $(if($leaseExp){$leaseExp}else{'unknown'})) }
        try {
            $ifi = Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ifi) { Write-KV "  Interface metric" ([string]$ifi.InterfaceMetric); Write-KV "  Adapter MTU" ("{0} bytes" -f $ifi.NlMtu) }
        } catch {}
        $ipv6g = ($cfg.IPv6Address | Where-Object { $_.IPAddress -notlike 'fe80*' } | Select-Object -First 1).IPAddress
        if ($ipv6g) { $hasIPv6Global=$true; Write-KV "  IPv6 (global)" $ipv6g }

        if ($gw) { $gateways += $gw }; if ($dns) { $dnsServers += $dns }
        if ($ipv4 -like '169.254.*') {
            $hasApipa = $true
            Add-Finding Critical 'IP' ("APIPA address ($ipv4) on '$($cfg.InterfaceAlias)'  - DHCP failed.") "The router never handed this PC an address. Renew DHCP, restart the router, set IP to Automatic." `
                -PlainWhat "This computer never received a proper address from your internet box, so it made up a temporary one that cannot reach the internet." `
                -PlainWhy "Every device needs a number from the home box (like a house number on your street). 169.254... means 'I asked and nobody answered.' You will see 'connected' to Wi-Fi but nothing online works." `
                -Playbooks @('ToggleWifi','EnableDhcp','RestartRouter','PlugCable','ForgetNetwork') -Priority 100
            Add-Remediation 'IP' "DHCP failed (self-assigned 169.254 address)" "Release & renew the DHCP lease" { ipconfig /release | Out-Null; Start-Sleep -Seconds 2; ipconfig /renew | Out-Null } ''
        } elseif ($origin -match 'Static' -and $gw) {
            Add-Finding Info 'IP' ("'$($cfg.InterfaceAlias)' uses a manual/static IPv4 address.") "Fine if you set it on purpose. Otherwise switch back to Automatic (DHCP) to avoid clashes." `
                -Playbooks @('EnableDhcp','IpConflict') -Priority 18
        }
        if ($cfg.InterfaceIndex -eq $script:PrimaryIfIndex) { $originPrimary = $origin; Set-Fact 'PrimaryIpv4' $ipv4; Set-Fact 'PrimaryKind' $kind }
    }
    $dnsServers = @($dnsServers | Select-Object -Unique); $gateways = @($gateways | Select-Object -Unique)
    $script:GwList=$gateways; $script:DnsList=$dnsServers
    Set-Fact 'Gateway' ($(if($gateways){$gateways[0]}else{''}))
    Set-Fact 'DnsServers' ($dnsServers -join ', ')
    Set-Fact 'HasApipa' $hasApipa

    if (-not $gateways) {
        Add-Finding Critical 'IP' "No default gateway configured." "No route off the LAN. Renew DHCP / check the router / plug the cable into a LAN port." `
            -PlainWhat "This computer does not know which box is the way out to the internet." `
            -PlainWhy "Without that 'next hop', traffic has nowhere to go, even if Wi-Fi shows a signal." `
            -Playbooks @('ToggleWifi','EnableDhcp','RestartRouter','PlugCable') -Priority 98
        Add-Remediation 'IP' "No default gateway" "Release & renew the DHCP lease" { ipconfig /release | Out-Null; Start-Sleep -Seconds 2; ipconfig /renew | Out-Null } ''
    }
    if (-not $dnsServers) {
        Add-Finding Critical 'IP' "No DNS servers configured." "Set DNS to 1.1.1.1 and 8.8.8.8, or renew DHCP." `
            -PlainWhat "This computer has no phone-book server for website names." `
            -Playbooks @('SwitchDns','EnableDhcp') -Priority 88
    }

    $defRoutes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $nh = @($defRoutes | Select-Object -Expand NextHop -Unique | Where-Object { $_ -and $_ -ne '0.0.0.0' })
    if ($nh.Count -gt 1) {
        Add-Finding Warning 'IP' ("Multiple default gateways: $($nh -join ', ').") "Two ways out (Wi-Fi + cable, or a VPN) can send traffic down a dead path. Disconnect the unused one to test." `
            -PlainWhat "Windows currently sees more than one 'way out' to the internet." `
            -PlainWhy "Traffic can take the wrong driveway. For a fair test, use only Wi-Fi or only a cable, not both, and disconnect VPN." `
            -Priority 44
    }

    try {
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            $usedIf = $route.InterfaceAlias
            if (-not $usedIf) { $usedIf = (Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue).Name }
            Write-KV "Internet exit path" ("{0}  ->  next box {1}" -f $(if($usedIf){$usedIf}else{"ifIndex $($route.InterfaceIndex)"}), $route.NextHop)
            Set-Fact 'EgressIf' $usedIf
            Set-Fact 'EgressHop' $route.NextHop
        }
    } catch {}

    if (-not $hasIPv6Global) { Add-Finding Info 'IP' "No global IPv6 address (IPv4-only)." "Usually fine; only matters for IPv6-only services." }
} catch { Write-Status Warning "Could not read IP configuration." }

# ==============================================================================
# 7. LOCAL NETWORK
# ==============================================================================
Write-Section "Your home box (gateway) & local network"
$gwReachable=$false; $gwArp=$false; $gwTcp=$false
foreach ($gw in $gateways) {
    Write-C ""
    Write-KV "Testing gateway" $gw 'White'
    $kind = Get-AddressKind $gw
    Write-KV "  Address type" $kind

    $neigh = $null
    try { $neigh = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $gw } | Select-Object -First 1 } catch {}
    if ($neigh) {
        Write-KV "  Neighbor (ARP)" ("{0}  MAC {1}" -f $neigh.State, $neigh.LinkLayerAddress)
        if ($neigh.State -match 'Reachable|Stale|Permanent|Delay|Probe') { $gwArp = $true }
        if ($neigh.State -eq 'Unreachable') {
            Add-Finding Warning 'LAN' ("Gateway $gw is Unreachable in the ARP table.") "The PC cannot map the router to a hardware address. Wrong subnet, or the box is off." `
                -PlainWhat "This computer cannot even see the home box on the local street." `
                -Playbooks @('RestartRouter','ToggleWifi','PlugCable') -Priority 75
        }
    } else {
        Write-KV "  Neighbor (ARP)" "no entry yet"
        try { $null = Test-TcpPort -Target $gw -Port 80 -TimeoutMs 800 } catch {}
        try {
            $neigh = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $gw } | Select-Object -First 1
            if ($neigh) { Write-KV "  Neighbor after probe" ("{0}  MAC {1}" -f $neigh.State, $neigh.LinkLayerAddress); if ($neigh.State -ne 'Unreachable') { $gwArp = $true } }
        } catch {}
    }

    $p = Measure-Ping -Target $gw -Count ([math]::Min(8,$PingCount)) -TimeoutMs 1000
    $col = if (-not $p.Reachable) { 'Yellow' } elseif ($p.LossPct -gt 0) { 'Yellow' } else { 'Green' }
    Write-C ("  Ping (ICMP)              : loss {0}%  avg {1} ms  jitter {2} ms" -f $p.LossPct,$p.AvgMs,$p.JitterMs) $col
    if ($p.Reachable) {
        $gwReachable = $true
        if ($p.LossPct -ge 5) {
            Add-Finding Warning 'LAN' ("Packet loss to gateway ($($p.LossPct)%).") "Flaky cable, Wi-Fi air, or a sick router." `
                -PlainWhat "Messages to your home box sometimes vanish." `
                -Playbooks @('PlugCable','ToggleWifi','RestartRouter') -Priority 62
        } elseif ($p.AvgMs -gt 15) {
            Add-Finding Warning 'LAN' ("High latency to gateway ($($p.AvgMs) ms).") "The first hop should usually be under 5-10 ms on a healthy LAN." `
                -PlainWhat "Even the box in your home is slow to answer." `
                -Playbooks @('PlugCable','Use5GHz','RestartRouter') -Priority 50
        } else { Add-Finding Good 'LAN' "Home gateway answers ping quickly with no loss." }
    }

    $t80  = Test-TcpTimed -Target $gw -Port 80  -TimeoutMs 2000
    $t443 = Test-TcpTimed -Target $gw -Port 443 -TimeoutMs 2000
    Write-C ("  Router web port 80/443   : {0} / {1}" -f $(if($t80.Success){"open ($($t80.Ms) ms)"}else{'no response'}), $(if($t443.Success){"open ($($t443.Ms) ms)"}else{'no response'})) $(if($t80.Success -or $t443.Success){'Green'}else{'DarkGray'})
    if ($t80.Success -or $t443.Success) { $gwTcp = $true }

    if (-not $p.Reachable -and ($gwArp -or $gwTcp)) {
        Add-Finding Info 'LAN' "Gateway does not answer ping, but it is visible locally (ARP/TCP)." "Many routers disable ping. This is not proof the box is dead." `
            -PlainWhat "Your home box is ignoring 'are you there?' pings, which is common and usually fine." `
            -Priority 8
        Write-Status Info "Ping is blocked; the box still looks present on the local network."
    }
}
Set-Fact 'GwPing' $gwReachable; Set-Fact 'GwArp' $gwArp; Set-Fact 'GwTcp' $gwTcp
if ($gateways -and -not $gwReachable -and -not $gwArp -and -not $gwTcp) {
    Add-Finding Warning 'LAN' "Gateway did not answer ping, ARP, or TCP." "The next box may be off, on another network, or this PC has a bad address." `
        -PlainWhat "We cannot confirm your home internet box is actually talking to this computer." `
        -Playbooks @('RestartRouter','ToggleWifi','EnableDhcp','PlugCable') -Priority 72
}

Write-C ""
foreach ($d in $dnsServers) {
    if ($d -like '127.*' -or $d -like '::1') { continue }
    $dp = Measure-Ping -Target $d -Count 4 -TimeoutMs 1000
    $rr = Measure-Dns -Name 'www.microsoft.com' -Server $d
    $col = if ($rr.Success) { 'Green' } elseif ($dp.Reachable) { 'Yellow' } else { 'Red' }
    Write-C ("  DNS server {0,-16} ping {1,-10} lookup {2}" -f $d, ($(if($dp.Reachable){"$($dp.AvgMs) ms"}else{'timeout'})), ($(if($rr.Success){"$($rr.Ms) ms OK"}else{'FAILED'}))) $col
    if (-not $rr.Success -and $d -eq $dnsServers[0]) {
        Add-Finding Critical 'DNS' ("Primary DNS server $d is not resolving names.") "Windows waits on this one first. Switch DNS to a working public resolver (1.1.1.1 / 8.8.8.8 / 9.9.9.9)." `
            -PlainWhat "The first 'phone book' this computer asks cannot look up website names." `
            -PlainWhy "Every page starts with a name lookup. If the first phone book never answers, Windows waits  - and the internet feels broken or painfully slow even when the cable is fine." `
            -Playbooks @('SwitchDns') -Priority 92
    }
}

try {
    $aliveLan = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Reachable' -and $_.IPAddress -notlike '127.*' })
    Write-KV "Other devices visible on LAN" ("{0} (ARP reachable)" -f $aliveLan.Count)
} catch {}

# ==============================================================================
# 8. INTERNET
# ==============================================================================
Write-Section "Internet (beyond your home)"
$targets = @(
    @{N='Google DNS';     Ip='8.8.8.8';     Port=443},
    @{N='Cloudflare DNS'; Ip='1.1.1.1';     Port=443},
    @{N='Quad9 DNS';      Ip='9.9.9.9';     Port=443}
)
$lat=@(); $los=@(); $tcpHits=0
Write-C "  Ping is a 'are you there' tap. TCP 443 is a real website-style connection." 'DarkGray'
Write-C ""
foreach ($t in $targets) {
    $p = Measure-Ping -Target $t.Ip -Count $PingCount -TimeoutMs 1500
    $tcp = Test-TcpTimed -Target $t.Ip -Port $t.Port -TimeoutMs 3000
    if ($p.Reachable) { $script:InternetUp=$true; $lat+=$p.AvgMs; $los+=$p.LossPct }
    if ($tcp.Success) { $script:InternetUp=$true; $tcpHits++ }
    $col = if (-not $p.Reachable -and -not $tcp.Success) { 'Red' } elseif ($p.LossPct -gt 2 -or $p.AvgMs -gt 120) { 'Yellow' } else { 'Green' }
    Write-C ("  {0,-16} {1,-9}  ping loss {2,5}%  avg {3,6} ms  jit {4,5}   TCP/{5} {6}" -f $t.N,$t.Ip,$p.LossPct,$p.AvgMs,$p.JitterMs,$t.Port, $(if($tcp.Success){"OK $($tcp.Ms)ms"}else{'FAIL'})) $col
}
Set-Fact 'InternetUp' $script:InternetUp
Set-Fact 'TcpHits' $tcpHits

if ($hasIPv6Global) {
    $p6 = Measure-Ping -Target '2606:4700:4700::1111' -Count 6 -TimeoutMs 1500
    Write-C ("  {0,-16} {1,-9}  ping loss {2,5}%  avg {3,6} ms" -f 'Cloudflare v6','IPv6',$p6.LossPct,$p6.AvgMs) $(if($p6.Reachable){'Green'}else{'Yellow'})
    if (-not $p6.Reachable) {
        Add-Finding Info 'Internet' "Has an IPv6 address but IPv6 internet is unreachable." "Broken IPv6 can delay some sites (they try IPv6 first, then fall back)." `
            -PlainWhat "The newer internet numbers (IPv6) are assigned but do not actually work." `
            -Priority 16
    }
}

if (-not $script:InternetUp) {
    Add-Finding Critical 'Internet' "No public internet reachable (ping and TCP to major resolvers failed)." "Restart the router/modem; check the ISP lights; try a cable; verify the WAN cable." `
        -PlainWhat "This computer cannot reach the public internet at all right now." `
        -PlainWhy "The problem is either this PC's address, the home box, or the internet company. We will tell you which is more likely after the other checks." `
        -Playbooks @('RestartRouter','ToggleWifi','PlugCable','EnableDhcp','CallIsp') -Priority 96
    if ($gwReachable -or $gwArp -or $gwTcp) {
        Add-Remediation 'Internet' "Internet down though the router is reachable" "Renew DHCP + flush DNS to re-establish the connection" { ipconfig /release | Out-Null; Start-Sleep -Seconds 2; ipconfig /renew | Out-Null; Clear-DnsClientCache } ''
        Add-Finding Info 'Internet' "The home box looks local, but the path beyond it is dead." "Classic ISP / modem WAN problem, or the router has no uplink." `
            -PlainWhat "Your home box is there, but it is not passing you through to the outside world." `
            -Playbooks @('RestartRouter','CallIsp') -Priority 94
    }
} else {
    if ($lat.Count) {
        $avgLat=[math]::Round((($lat|Measure-Object -Average).Average),0); $avgLoss=[math]::Round((($los|Measure-Object -Average).Average),1)
        Set-Fact 'AvgLat' $avgLat; Set-Fact 'AvgLoss' $avgLoss
        if ($avgLoss -ge 10) {
            Add-Finding Critical 'Internet' ("Severe packet loss (~${avgLoss}%).") "Bad Wi-Fi, bad cable, or an unstable ISP/modem line." `
                -PlainWhat "A lot of internet traffic is getting lost on the way." `
                -Playbooks @('PlugCable','RestartRouter','CallIsp') -Priority 85
        } elseif ($avgLoss -ge 2) {
            Add-Finding Warning 'Internet' ("Packet loss (~${avgLoss}%).") "Causes stalls and buffering." `
                -Playbooks @('PlugCable','Use5GHz','RestartRouter') -Priority 58
        } else { Add-Finding Good 'Internet' "Internet reachable with minimal loss." }
        if ($avgLat -ge 150) {
            Add-Finding Warning 'Internet' ("High latency (~$avgLat ms).") "Slow/overloaded link or a long ISP path (see the route)." `
                -PlainWhat "The internet is answering, but slowly  - like a conversation with a long pause after every sentence." `
                -Playbooks @('PlugCable','Use5GHz','CallIsp') -Priority 54
        } elseif ($avgLat -ge 80) {
            Add-Finding Info 'Internet' ("Elevated latency (~$avgLat ms).") "Usable, not snappy. Common on congested Wi-Fi, DSL, or mobile." -Priority 20
        } else { Add-Finding Good 'Internet' ("Good latency (~$avgLat ms).") }
    }
    if ($tcpHits -eq 0) {
        Add-Finding Warning 'Internet' "Ping works but TCP 443 to public resolvers failed." "Firewall, filtering, or a captive portal may be blocking web traffic." `
            -PlainWhat "A simple tap works, but real website connections are being blocked." `
            -Priority 70
    } else { Add-Finding Good 'Internet' "Real TCP connections to the internet succeed." }
}

# ==============================================================================
# 9. DNS
# ==============================================================================
Write-Section "Website names (DNS)"
$names=@('www.microsoft.com','google.com','cloudflare.com','wikipedia.org')
$defTimes=@(); $defFail=0
foreach ($n in $names) { $r=Measure-Dns -Name $n; if ($r.Success){ $defTimes+=$r.Ms } else { $defFail++ } }
$defAvg= if ($defTimes.Count){ [math]::Round((($defTimes|Measure-Object -Average).Average),0) } else { -1 }
Write-C ("  Current name lookup        : avg {0} ms   ({1}/{2} names resolved)" -f ($(if($defAvg -ge 0){$defAvg}else{'n/a'})),($names.Count-$defFail),$names.Count) $(if($defFail){'Red'}elseif($defAvg -ge 300){'Yellow'}else{'Green'})
$pub=@{}
foreach ($srv in @('8.8.8.8','1.1.1.1','9.9.9.9')) {
    $r=Measure-Dns -Name 'www.microsoft.com' -Server $srv; $pub[$srv]=$r
    Write-C ("  Direct via {0,-12}    : {1}" -f $srv,($(if($r.Success){"$($r.Ms) ms"}else{'FAILED'}))) $(if(-not $r.Success){'Red'}elseif($r.Ms -ge 300){'Yellow'}else{'Green'})
}
$script:BestPublicDns=@($pub.GetEnumerator()|Where-Object {$_.Value.Success}|Sort-Object {$_.Value.Ms}|Select-Object -Expand Key)
if ($script:BestPublicDns.Count) { Set-Fact 'BestDns' ([string]$script:BestPublicDns[0]) }
Set-Fact 'DnsAvg' $defAvg

$dnsProblem=$false
if ($defFail -eq $names.Count) {
    $dnsProblem=$true
    Add-Finding Critical 'DNS' "Current resolver cannot resolve names at all." "IPs may work (you could ping 8.8.8.8) but no site names load. Switch DNS." `
        -PlainWhat "Website names cannot be translated into numbers at all right now." `
        -PlainWhy "Typing facebook.com is useless if the phone book is empty. Apps that already know numbers might still work, which is confusing." `
        -Playbooks @('SwitchDns') -Priority 93
} elseif ($defFail -gt 0) {
    $dnsProblem=$true
    Add-Finding Warning 'DNS' "$defFail/$($names.Count) DNS lookups failed on the current resolver." "Pages will 'sometimes' fail to load." `
        -Playbooks @('SwitchDns') -Priority 60
}
$bestPub=($pub.Values|Where-Object Success|Sort-Object Ms|Select-Object -First 1)
if ($defAvg -ge 0 -and $bestPub) {
    if ($defAvg -ge 800) {
        $dnsProblem=$true
        Add-Finding Critical 'DNS' ("DNS is extremely slow (avg $defAvg ms) vs $($bestPub.Ms) ms on $($bestPub.Server).") "The #1 cause of 'the internet feels slow'. Switch DNS to $($bestPub.Server)." `
            -PlainWhat "Looking up each website name is taking almost a second." `
            -PlainWhy "Every tab and app pays that tax before anything appears. Changing the phone book (DNS) is safe and often feels like a new internet." `
            -Playbooks @('SwitchDns') -Priority 86
    } elseif ($defAvg -ge 250 -and $defAvg -gt ($bestPub.Ms*3)) {
        $dnsProblem=$true
        Add-Finding Warning 'DNS' ("DNS is slow (avg $defAvg ms)  - about $([math]::Round($defAvg/[math]::Max($bestPub.Ms,1),1))x slower than $($bestPub.Server) ($($bestPub.Ms) ms).") "Switching DNS to $($bestPub.Server) makes browsing snappier." `
            -PlainWhat "Website names load, but the lookup is slow compared with a public phone book." `
            -Playbooks @('SwitchDns') -Priority 56
    } else { Add-Finding Good 'DNS' ("DNS lookup is healthy (avg $defAvg ms).") }
}
if ($Fix) { Add-Remediation 'DNS' "Stale DNS cache" "Flush the DNS resolver cache" { Clear-DnsClientCache } '' }
if ($dnsProblem -and $script:BestPublicDns.Count -and $script:PrimaryIfIndex) {
    $dnsPick=@($script:BestPublicDns|Select-Object -First 2); if ($dnsPick.Count -lt 2){ $dnsPick=@($dnsPick + '1.1.1.1' | Select-Object -Unique) }
    $dnsIfIdx=$script:PrimaryIfIndex; $dnsNew=$dnsPick
    $oldDns=@((Get-DnsClientServerAddress -InterfaceIndex $dnsIfIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    $revert= if ($oldDns.Count){ "Set-DnsClientServerAddress -InterfaceIndex $dnsIfIdx -ServerAddresses $($oldDns -join ',')" } else { "Set-DnsClientServerAddress -InterfaceIndex $dnsIfIdx -ResetServerAddresses" }
    Add-Remediation 'DNS' "Configured DNS is slow/broken" ("Set '$($script:PrimaryIfAlias)' DNS to $($dnsNew -join ', ')") ({ Set-DnsClientServerAddress -InterfaceIndex $dnsIfIdx -ServerAddresses $dnsNew -ErrorAction Stop; Clear-DnsClientCache }.GetNewClosure()) $revert
}

# ==============================================================================
# 10. PATH, NAT, MTU
# ==============================================================================
Write-Section "The route out (path, NAT, MTU)"
$doubleNat=$false; $cgnat=$false; $natHops=0; $pathMtu=$null
if ($Quick) { Write-Status Info "Route/MTU skipped in Quick mode." }
elseif (-not $script:InternetUp) { Write-Status Info "Skipped  - no internet path to trace." }
else {
    Write-Wrap "Each line is one stop between you and a Google server. A jump in delay shows where slowness starts. Private numbers in a row mean extra home boxes (double NAT)." 'DarkGray'
    Write-C ""
    $dest='8.8.8.8'; $prev=0; $jump=$null; $ping=New-Object System.Net.NetworkInformation.Ping; $buf=New-Object byte[] 32
    for ($ttl=1; $ttl -le 20; $ttl++) {
        $opt=New-Object System.Net.NetworkInformation.PingOptions($ttl,$false); $hop='*'; $rtt=$null; $status='TimedOut'
        try {
            $sw=[System.Diagnostics.Stopwatch]::StartNew(); $rep=$ping.Send($dest,1500,$buf,$opt); $sw.Stop()
            if ($rep.Address) { $hop=$rep.Address.ToString(); $rtt=[math]::Round($sw.Elapsed.TotalMilliseconds,0) }
            $status=$rep.Status
        } catch { $status='Error' }
        $kind = if ($hop -ne '*') { Get-AddressKind $hop } else { '' }
        $col='Gray'
        if ($rtt -ne $null) {
            if ($prev -gt 0 -and ($rtt-$prev) -ge 80) { $col='Yellow'; if (-not $jump) { $jump=@{Hop=$ttl;From=$prev;To=$rtt} } }
            $prev=$rtt
        }
        if ($kind -eq 'CGNAT') { $col='Yellow'; $cgnat=$true }
        if ($kind -eq 'Private' -or $kind -eq 'CGNAT') { $natHops++ }
        $script:Hops.Add([pscustomobject]@{ Ttl=$ttl; Address=$hop; Ms=$rtt; Kind=$kind })
        $kindTag = if ($kind) { "  [$kind]" } else { '' }
        Write-C ("  {0,2}  {1,-18} {2,-10}{3}" -f $ttl,$hop,($(if($rtt -ne $null){"$rtt ms"}else{'*'})),$kindTag) $col
        if ($status -eq 'Success') { break }
    }

    $privHops = @($script:Hops | Where-Object { $_.Kind -eq 'Private' -and $_.Address -ne '*' })
    $gw0 = Get-Fact 'Gateway'
    if ($privHops.Count -ge 2) { $doubleNat = $true }
    elseif ($privHops.Count -ge 1 -and $gw0 -and $privHops[0].Address -ne $gw0) { $doubleNat = $true }
    Set-Fact 'DoubleNat' $doubleNat; Set-Fact 'Cgnat' $cgnat

    if ($doubleNat) {
        Add-Finding Warning 'Path' "Double NAT detected (more than one private network in a row)." "Two routers are sharing the connection. Put the extra box in Access Point mode, or plug into the main ISP box." `
            -PlainWhat "Your internet is going through two home boxes stacked on top of each other." `
            -PlainWhy "Each box hides your devices behind its own numbers. Games, video calls, printers, and some apps misbehave. It also adds delay." `
            -Playbooks @('DoubleNat','PlugCable') -Priority 47
    }
    if ($cgnat) {
        Add-Finding Info 'Path' "CGNAT detected (100.64.x.x)  - the ISP is sharing a public address among many homes." "Normal for some fiber/mobile ISPs. Inbound connections / some peer games may fail unless the ISP gives you a public IP." `
            -PlainWhat "Your internet company is sharing one public address among many customers." `
            -PlainWhy "You did nothing wrong. Some games and remote-access tools dislike this. Only the provider can give you a real public address." `
            -Playbooks @('CallIsp') -Priority 14
    }

    if ($jump) {
        $where = if ($jump.Hop -le 1) { 'your local network / home box' } elseif ($jump.Hop -le 3) { "your internet company's nearby equipment" } else { 'the wider internet path' }
        Add-Finding Info 'Path' ("Latency jumps {0}->{1} ms at hop {2} ({3})." -f $jump.From,$jump.To,$jump.Hop,$where) "That is where delay enters: hop 1 = home, early hops = ISP, later = the internet at large." `
            -PlainWhat ("A big pause appears at stop {0} ({1})." -f $jump.Hop, $where) `
            -Priority 24
    } else { Add-Finding Good 'Path' "No abnormal latency spikes along the route." }

    $opt=New-Object System.Net.NetworkInformation.PingOptions; $opt.DontFragment=$true
    if (Test-PingSize -Target $dest -Size 1472 -Opt $opt) { $pathMtu=1500 }
    else {
        $lo=1200;$hi=1472;$best=0
        while ($lo -le $hi) { $mid=[int](($lo+$hi)/2); if (Test-PingSize -Target $dest -Size $mid -Opt $opt) { $best=$mid;$lo=$mid+1 } else { $hi=$mid-1 } }
        if ($best) { $pathMtu=$best+28 }
    }
    if ($pathMtu) {
        Write-KV "Path MTU" "$pathMtu bytes"
        Set-Fact 'PathMtu' $pathMtu
        if ($pathMtu -lt 1500) {
            Add-Finding Info 'Path' ("Path MTU is $pathMtu (below 1500).") "Common on PPPoE/VPN. If large pages hang, match the router/adapter MTU to $pathMtu." `
                -PlainWhat "The internet path only accepts slightly smaller packets than usual." `
                -Priority 12
        }
    } else { Write-Status Info "MTU probe inconclusive (some networks filter this test)." }
}

# ==============================================================================
# 11. WEB
# ==============================================================================
Write-Section "Websites (HTTP, HTTPS, captive portal, clock, proxy)"
$webOk=$false; $httpsOk=$false; $proxyActive=$false; $captive=$false
try {
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    $resp=Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 8 -MaximumRedirection 0
    $sw.Stop()
    if ($resp.Content -match 'Microsoft Connect Test') {
        $webOk=$true
        Write-Status Good ("HTTP works ($([math]::Round($sw.Elapsed.TotalMilliseconds,0)) ms).")
        Add-Finding Good 'Web' "Direct HTTP works; no captive portal on the Microsoft test."
    } else {
        $captive=$true
        Add-Finding Warning 'Web' "Unexpected HTTP response  - possible sign-in page (captive portal)." "Open a browser and complete the hotel/cafe/guest Wi-Fi login." `
            -PlainWhat "This network is probably waiting for you to sign in on a web page." `
            -Priority 65
        Write-Status Warning "Possible captive portal."
    }
} catch {
    if ($_.Exception.Message -match '30[0-9]|redirect') {
        $captive=$true
        Add-Finding Warning 'Web' "HTTP redirected  - captive portal likely." "Open a browser and complete the login page." `
            -PlainWhat "The network bounced you to a sign-in page instead of the real internet." `
            -Priority 66
        Write-Status Warning "Captive portal detected."
    } elseif ($script:InternetUp) {
        Add-Finding Warning 'Web' "Ping/TCP works but HTTP failed." "Firewall/proxy/DNS, or a filtering box." `
            -Playbooks @('DisableProxy') -Priority 58
        Write-Status Warning "HTTP failed though the internet looks reachable."
    } else { Write-Status Info "HTTP test skipped (no internet)." }
}
try {
    $r2=Invoke-WebRequest -Uri 'https://www.google.com/generate_204' -UseBasicParsing -TimeoutSec 8
    if ($r2.StatusCode -in 200,204) { $httpsOk=$true; Write-Status Good "HTTPS/TLS (secure websites) works." }
} catch {
    if ($script:InternetUp) {
        Add-Finding Warning 'Web' "HTTPS request failed." "Wrong clock, TLS inspection, or a proxy. Check date/time and proxy settings." `
            -Playbooks @('FixClock','DisableProxy') -Priority 57
    }
}
Set-Fact 'WebOk' $webOk; Set-Fact 'HttpsOk' $httpsOk; Set-Fact 'Captive' $captive

try {
    $r3=Invoke-WebRequest -Uri 'https://www.cloudflare.com' -UseBasicParsing -TimeoutSec 8 -Method Head
    $sd=$r3.Headers['Date']
    if ($sd) {
        $delta=([datetime]$sd).ToUniversalTime()-(Get-Date).ToUniversalTime()
        Write-KV "Clock vs internet" ("off by {0} minutes" -f [math]::Round($delta.TotalMinutes,1)) $(if([math]::Abs($delta.TotalMinutes) -gt 5){'Red'}else{'Green'})
        if ([math]::Abs($delta.TotalMinutes) -gt 5) {
            Add-Finding Warning 'System' ("Clock off by ~{0} min vs the internet." -f [math]::Round($delta.TotalMinutes,0)) "A wrong clock breaks secure websites. Turn on automatic time." `
                -PlainWhat "This computer's clock is wrong." `
                -PlainWhy "Secure sites refuse to talk when they think the date is imaginary." `
                -Playbooks @('FixClock') -Priority 50
            Add-Remediation 'System' "System clock is wrong (breaks HTTPS)" "Restart Windows Time service and resync the clock" { Start-Service w32time -ErrorAction SilentlyContinue; & w32tm /resync /force | Out-Null } ''
        }
    }
} catch {}

try {
    $wp=netsh winhttp show proxy 2>$null
    if ($wp -match 'Proxy Server\(s\)\s*:\s*(\S+)') { $proxyActive=$true; Add-Finding Info 'Proxy' ("WinHTTP proxy set: $($Matches[1]).") "If that proxy is dead, apps using WinHTTP break." }
    $inet=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($inet.AutoConfigURL) {
        Add-Finding Info 'Proxy' ("Automatic proxy script: $($inet.AutoConfigURL)") "A leftover WPAD/PAC script can slow or break the web." -Playbooks @('DisableProxy') -Priority 26
    }
    if ($inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
        $proxyActive=$true
        Add-Finding Warning 'Proxy' ("System proxy enabled: $($inet.ProxyServer).") "A leftover work/school proxy makes home internet look broken." `
            -PlainWhat "This PC is trying to send the web through another computer (a proxy)." `
            -PlainWhy "That is normal at some offices. At home it is usually leftover settings and everything looks 'offline'." `
            -Playbooks @('DisableProxy') -Priority 64
        $oldPS=$inet.ProxyServer
        if (-not $webOk) {
            Add-Remediation 'Proxy' "A proxy is set and web traffic is failing" "Disable the WinINET system proxy + reset WinHTTP proxy" { Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0; netsh winhttp reset proxy | Out-Null } ("Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 1; (re-enter proxy $oldPS)")
        }
    }
} catch {}

if ($script:InternetUp -and -not $webOk -and -not $proxyActive -and -not $dnsProblem -and -not $captive) {
    Add-Finding Warning 'Web' "Network stack may be corrupted (IP+DNS work, web does not)." "A Winsock/TCP-IP reset often fixes this (needs a reboot)." `
        -PlainWhat "The plumbing inside Windows looks bent: numbers work, names work, but web pages do not." `
        -Playbooks @('RebootPc') -Priority 55
    Add-Remediation 'Web' "Web fails despite working IP & DNS (possible Winsock corruption)" "Reset Winsock + TCP/IP stack" { netsh winsock reset | Out-Null; netsh int ip reset | Out-Null } '' -NeedsReboot -DeepOnly
}

# ==============================================================================
# 12. FIREWALL / VPN / HOSTS
# ==============================================================================
Write-Section "Firewall, VPN & hosts file"
try {
    $fw=Get-NetFirewallProfile -ErrorAction SilentlyContinue
    if ($fw) {
        $on=@($fw|Where-Object {$_.Enabled}).Count
        Write-KV "Firewall profiles on" ("{0}/{1} ({2})" -f $on,$fw.Count,(($fw|ForEach-Object {"$($_.Name)=$([int]$_.Enabled)"}) -join ' '))
        if ($on -eq 0) { Add-Finding Info 'Security' "All Windows Firewall profiles are OFF." "Not a speed issue, but a security risk." }
    }
} catch {}
try {
    $vpnAd=Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and (Test-IsVirtualAdapter $_) }
    if ($vpnAd) {
        foreach ($v in $vpnAd) { Write-KV "VPN/virtual adapter" $v.InterfaceDescription 'Yellow' }
        Add-Finding Info 'VPN' ("Active VPN/virtual adapter: $((($vpnAd|Select-Object -Expand InterfaceDescription) -join '; ')).") "A VPN adds delay and can cut speed. Disconnect it to test the real line." `
            -PlainWhat "A VPN or virtual network is on." `
            -PlainWhy "Your traffic takes a detour through another company's servers. That can look like 'the internet is slow'." `
            -Priority 32
    }
    $vpnConn=Get-VpnConnection -ErrorAction SilentlyContinue | Where-Object { $_.ConnectionStatus -eq 'Connected' }
    if ($vpnConn) {
        Add-Finding Info 'VPN' ("Connected VPN: $((($vpnConn|Select-Object -Expand Name) -join '; ')).") "If slowness only happens on VPN, the tunnel is the bottleneck." -Priority 32
        Set-Fact 'Vpn' $true
    }
} catch {}
try {
    $hp="$env:SystemRoot\System32\drivers\etc\hosts"
    if (Test-Path $hp) {
        $lines=Get-Content $hp -ErrorAction SilentlyContinue
        $entries=@($lines | Where-Object { $_ -and ($_ -notmatch '^\s*#') -and ($_ -match '\S') })
        $nonLocal=@($entries | Where-Object { $_ -notmatch '^\s*(127\.0\.0\.1|::1)\s' })
        Write-KV "Hosts file entries" ("{0} active ({1} non-localhost)" -f $entries.Count,$nonLocal.Count)
        if ($nonLocal.Count -gt 0) {
            $sev='Info'; $rec="Entries here override DNS for those names."
            if ($nonLocal -match 'microsoft|windowsupdate|google|facebook|update') { $sev='Warning'; $rec="Well-known sites are redirected  - review $hp." }
            Add-Finding $sev 'Security' ("Hosts file has $($nonLocal.Count) custom redirect(s).") $rec -Priority 20
            foreach ($nl in ($nonLocal|Select-Object -First 5)) { Write-C ("      hosts> $nl") 'DarkYellow' }
        }
    }
} catch {}

# ==============================================================================
# 13. TCP TUNING
# ==============================================================================
Write-Section "Speed plumbing (TCP tuning)"
try {
    $g=netsh int tcp show global 2>$null
    $atl=($g|Select-String -Pattern 'Auto-Tuning Level\s*:\s*(\S+)').Matches.Groups[1].Value
    if ($atl) {
        Write-KV "Receive Window Auto-Tuning" $atl
        if ($atl -match 'disabled') {
            Add-Finding Warning 'Tuning' "TCP receive-window auto-tuning is DISABLED." "This caps download speed on fast or high-latency links. Set it back to normal." `
                -PlainWhat "A hidden Windows speed setting is turned off, which can cap downloads." `
                -Priority 43
            Add-Remediation 'Tuning' "TCP auto-tuning disabled (limits throughput)" "Set TCP auto-tuning level back to normal" { netsh int tcp set global autotuninglevel=normal | Out-Null } ("netsh int tcp set global autotuninglevel=disabled")
        } else { Add-Finding Good 'Tuning' "TCP auto-tuning is enabled ($atl)." }
    }
} catch {}

# ==============================================================================
# 14. THROUGHPUT
# ==============================================================================
Write-Section "Speed sample (download)"
if ($Quick -or -not $script:InternetUp) { Write-Status Info ($(if($Quick){'Skipped in Quick mode.'}else{'Skipped  - no internet.'})) }
else {
    $maxSecs=12; $bytes=5000000
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $client=New-Object System.Net.Http.HttpClient; $client.Timeout=[TimeSpan]::FromSeconds($maxSecs)
        $sw=[System.Diagnostics.Stopwatch]::StartNew(); $len=0; $to=$false
        try { $data=$client.GetByteArrayAsync("https://speed.cloudflare.com/__down?bytes=$bytes").GetAwaiter().GetResult(); $len=$data.Length } catch { $to=$true }
        $sw.Stop(); $secs=[math]::Max($sw.Elapsed.TotalSeconds,0.001)
        if ($len -gt 0) {
            $mbps=[math]::Round((($len*8)/$secs)/1MB,1)
            Set-Fact 'Mbps' $mbps
            Write-C ("  Downloaded {0} MB in {1}s   =>   {2} Mbps (one stream)" -f ([math]::Round($len/1MB,1)),[math]::Round($secs,2),$mbps) $(if($mbps -lt 5){'Red'}elseif($mbps -lt 25){'Yellow'}else{'Green'})
            if ($mbps -lt 5) {
                Add-Finding Warning 'Speed' ("Low throughput (~$mbps Mbps single-stream).") "Slow plan, congestion, or weak Wi-Fi. Compare with a cable if you can." `
                    -PlainWhat "A small download was much slower than a modern home connection should be." `
                    -Playbooks @('PlugCable','Use5GHz','RestartRouter','CallIsp') -Priority 50
            } elseif ($mbps -lt 25) {
                Add-Finding Info 'Speed' ("Moderate throughput (~$mbps Mbps single-stream).") "Fine for browsing; HD video may struggle if others share the line." -Priority 18
            } else { Add-Finding Good 'Speed' ("Healthy throughput (~$mbps Mbps single-stream).") }
        } elseif ($to) {
            Write-C ("  Download did not finish within {0}s  - the link is very slow or blocked." -f $maxSecs) 'Red'
            Add-Finding Warning 'Speed' ("Very low throughput (could not pull 5 MB in ${maxSecs}s).") "Confirms a slow, congested, or filtered link. Try a cable and a router reboot." `
                -PlainWhat "We could not even download a small test file in time." `
                -Playbooks @('PlugCable','RestartRouter','Use5GHz','CallIsp') -Priority 60
        } else { Write-Status Info "Throughput test could not run." }
        $client.Dispose()
    } catch { Write-Status Info "Throughput test could not run." }
}

# ==============================================================================
# 15. CONNECTION MAP + PLAIN ENGLISH + STEPS
# ==============================================================================
Write-Section "Picture of your connection"

function Write-MapLine { param([string]$Text, [string]$Color='White') Write-C ("      {0}" -f $Text) $Color }

Write-C ""
Write-C "      THIS COMPUTER  ($($env:COMPUTERNAME))" 'White'
$ethBit = if (Get-Fact 'EthUp') { 'CABLE connected' } elseif (Get-Fact 'EthDisconnected') { 'CABLE port empty' } elseif (Get-Fact 'EthPresent') { 'CABLE not up' } else { 'no cable port seen' }
$wifiBit = if ($wifiConnected) { "WI-FI to `"$ssid`" ($myBand, ch $myChannel)" } elseif (Get-Fact 'WifiPresent') { 'WI-FI present, not joined' } else { 'no Wi-Fi seen' }
$eg = Get-Fact 'EgressIf'
if ($eg) { Write-MapLine ("using: {0}     [{1} | {2}]" -f $eg, $ethBit, $wifiBit) 'Cyan' }
else { Write-MapLine ("[{0} | {1}]" -f $ethBit, $wifiBit) 'Cyan' }

$ipShow = Get-Fact 'PrimaryIpv4'
if ($ipShow) {
    $ipCol = if (Get-Fact 'HasApipa') { 'Red' } else { 'Green' }
    Write-MapLine '|' 'DarkGray'
    Write-MapLine ("address: {0}" -f $ipShow) $ipCol
}
Write-MapLine '|' 'DarkGray'
$gwShow = Get-Fact 'Gateway'
if ($gwShow) {
    $gCol = if ((Get-Fact 'GwPing') -or (Get-Fact 'GwArp') -or (Get-Fact 'GwTcp')) { 'Green' } else { 'Yellow' }
    Write-MapLine ("v  home box (gateway) {0}" -f $gwShow) $gCol
} else {
    Write-MapLine 'v  home box: UNKNOWN (no gateway)' 'Red'
}

$drawnPriv = $false
foreach ($h in $script:Hops) {
    if ($h.Address -eq '*' -or $h.Ttl -eq 1 -and $gwShow -and $h.Address -eq $gwShow) { continue }
    if ($h.Kind -eq 'Private' -and $h.Address -ne $gwShow) {
        Write-MapLine '|' 'DarkGray'
        Write-MapLine ("v  another home/office box  {0}" -f $h.Address) 'Yellow'
        $drawnPriv = $true
    } elseif ($h.Kind -eq 'CGNAT') {
        Write-MapLine '|' 'DarkGray'
        Write-MapLine ("v  internet company (shared address)  {0}" -f $h.Address) 'Yellow'
        break
    } elseif ($h.Kind -eq 'Public') {
        Write-MapLine '|' 'DarkGray'
        Write-MapLine 'v  internet company  ->  the rest of the internet' $(if(Get-Fact 'InternetUp'){'Green'}else{'Red'})
        break
    }
}
if (-not $script:Hops.Count) {
    Write-MapLine '|' 'DarkGray'
    Write-MapLine ('v  internet: ' + $(if(Get-Fact 'InternetUp'){'REACHABLE'}else{'NOT REACHABLE'})) $(if(Get-Fact 'InternetUp'){'Green'}else{'Red'})
}

# ----- Plain English -----
Write-C ""
Write-Rule 'Cyan'
Write-C "  WHAT IS GOING ON  (plain language, no jargon)" 'White'
Write-Rule 'Cyan'
Write-C ""

$crit=@($script:Findings|Where-Object Severity -eq 'Critical')
$warn=@($script:Findings|Where-Object Severity -eq 'Warning')
$good=@($script:Findings|Where-Object Severity -eq 'Good')
$info=@($script:Findings|Where-Object Severity -eq 'Info')

$verdict='Looks healthy'
$verdictPlain='This computer''s network looks in good shape from here to the internet.'
$vcol='Green'
if ($crit.Count) {
    $verdict='Needs attention'
    $verdictPlain='Something important is broken. The internet on this PC is not working as it should.'
    $vcol='Red'
} elseif ($warn.Count) {
    $verdict='Working, but not well'
    $verdictPlain='You can probably get online, but there are problems that make it slow, flaky, or fragile.'
    $vcol='Yellow'
}

Write-C ("  Bottom line:  {0}" -f $verdict) $vcol
Write-Wrap $verdictPlain $vcol
Write-C ("  ({0} serious, {1} warnings, {2} healthy checks, {3} notes)" -f $crit.Count,$warn.Count,$good.Count,$info.Count) 'DarkGray'
Write-C ""

$storyBits = New-Object System.Collections.Generic.List[string]
if (Get-Fact 'Airplane') { [void]$storyBits.Add("Airplane mode is on, so wireless is deliberately switched off.") }
if (Get-Fact 'HasApipa') { [void]$storyBits.Add("Wi-Fi or the cable may show as connected, but the home box never gave this PC a real address (it is using a 169.254 'placeholder'). That is why the internet is dead.") }
elseif (-not (Get-Fact 'Gateway')) { [void]$storyBits.Add("This PC does not know which box is the way out, so traffic has nowhere to go.") }
if ($wifiConnected -and (Get-Fact 'On24')) { [void]$storyBits.Add("You are on 2.4 GHz Wi-Fi (the older, more crowded radio). A cable, or 5 GHz if you have it, is almost always smoother.") }
if ((Get-Fact 'EthDisconnected') -and $wifiConnected) { [void]$storyBits.Add("There is a cable port on this machine sitting empty. Plugging into the router is the single most reliable upgrade.") }
if (Get-Fact 'DoubleNat') { [void]$storyBits.Add("Traffic is passing through more than one home/office box (two layers of sharing). That extra hop is a classic cause of weird game, call, and printer problems.") }
if (Get-Fact 'Cgnat') { [void]$storyBits.Add("Your internet company is sharing a public address among many homes. You cannot fix that on the PC.") }
if ($captive) { [void]$storyBits.Add("The network looks like it wants a browser sign-in (hotel, cafe, guest Wi-Fi, or a school splash page).") }
if ((Get-Fact 'DnsAvg') -is [int] -and (Get-Fact 'DnsAvg') -ge 250) { [void]$storyBits.Add("Looking up website names is slow, so every new page feels sticky even when the line is up.") }
if (-not (Get-Fact 'InternetUp') -and ((Get-Fact 'GwArp') -or (Get-Fact 'GwPing') -or (Get-Fact 'GwTcp'))) { [void]$storyBits.Add("The home box is there, but the outside internet is not  - that pattern usually means the provider or the box's WAN/internet light, not this PC.") }
elseif (-not (Get-Fact 'InternetUp') -and -not (Get-Fact 'HasApipa')) { [void]$storyBits.Add("Nothing on the public internet answered. Start with the home box lights and a reboot of that box.") }
if ((Get-Fact 'Mbps') -ne $null -and (Get-Fact 'Mbps') -lt 8) { [void]$storyBits.Add("A small download test was very slow, which matches a congested Wi-Fi, a strained box, or a weak internet plan/line.") }

if ($storyBits.Count) {
    Write-C "  In everyday terms:" 'White'
    $n=1
    foreach ($b in $storyBits) { Write-Wrap ("{0}. {1}" -f $n, $b) 'Gray'; $n++ }
} else {
    Write-Wrap "No major story to tell  - the checks we ran look consistent with a normal, working connection." 'Green'
}

Write-C ""
Write-C "  The important problems, in plain words:" 'White'
$told=0
foreach ($f in @($script:Findings | Where-Object { $_.Severity -in 'Critical','Warning' } | Sort-Object { -$_.Priority })) {
    $what = if ($f.PlainWhat) { $f.PlainWhat } else { $f.Message }
    $why  = $f.PlainWhy
    Write-C ("    - {0}" -f $what) (Get-Color $f.Severity)
    if ($why) { Write-Wrap ("      Why it matters: {0}" -f $why) 'DarkGray' }
    $told++
    if ($told -ge 8) { break }
}
if ($told -eq 0) { Write-C "    - Nothing worrying turned up." 'Green' }

# ----- Step by step -----
Write-C ""
Write-Rule 'Cyan'
Write-C "  HOW TO FIX IT  (do these in order, then re-run Net Doctor)" 'White'
Write-Rule 'Cyan'
Write-C ""

$playOrder = @(
    'AirplaneOff','StartServices','EnableAdapter','PlugCable','ToggleWifi','EnableDhcp','ForgetNetwork',
    'RestartRouter','SwitchDns','Use5GHz','RouterChannel','DisablePowerSaving','DisableProxy','FixClock',
    'IpConflict','DoubleNat','UpdateDriver','RebootPc','CallIsp'
)
$wanted = @()
foreach ($f in $script:Findings) {
    if ($f.Severity -notin @('Critical','Warning')) { continue }
    if (-not $f.PlaybookList) { continue }
    foreach ($p in @($f.PlaybookList -split ',')) {
        $p = ([string]$p).Trim()
        if ($p -and $wanted -notcontains $p) { $wanted += $p }
    }
}
$ordered = @($playOrder | Where-Object { $wanted -contains $_ })
if (-not (Get-Fact 'EthPresent')) {
    $ordered = @($ordered | Where-Object { $_ -ne 'PlugCable' })
}
if ($crit.Count -eq 0 -and $warn.Count -eq 0) {
    Write-Wrap "Nothing to fix. If a device still misbehaves, try a cable instead of Wi-Fi, or restart the internet box once." 'Green'
} elseif (-not $ordered.Count) {
    Write-C "  1. Restart the internet box: unplug it for 30 seconds, plug it back in, wait 2 minutes." 'Yellow'
    Write-C "  2. Click the Wi-Fi icon (bottom-right), turn Wi-Fi off, wait 10 seconds, turn it on." 'Yellow'
    if (Get-Fact 'EthPresent') {
        Write-C "  3. If you have a network cable, plug this PC into the internet box and try again." 'Yellow'
    }
    Write-Wrap "Read the notes below for anything more specific." 'Gray'
} else {
    $stepNo=1
    foreach ($bookId in $ordered) {
        $pb = Get-Playbook -Id $bookId
        $title = $null; $steps = @()
        if ($pb) { $title = [string]$pb.Title; $steps = @($pb.Steps) }
        if ($bookId -eq 'SwitchDns') {
            $bestDns = Get-Fact 'BestDns'
            if ($bestDns) { $title = "Change DNS to $bestDns so website names load faster" }
        }
        if (-not $title) { $title = $bookId }
        Write-C ("  Step {0}.  {1}" -f $stepNo, $title) 'Yellow'
        if ($steps.Count) {
            $i=1
            foreach ($s in $steps) {
                Write-Wrap ("       {0}) {1}" -f $i, $s) 'Gray'
                $i++
            }
        }
        Write-C ""
        $stepNo++
        if ($stepNo -gt 8) { break }
    }
    Write-Wrap "After you finish a step, try a website. If it is still wrong, continue. When you are done, run Net Doctor again to see what changed." 'DarkGray'
    if (-not (Get-Fact 'EthPresent')) {
        Write-Wrap "This PC has no cable port that Windows can see. The most stable extra option is a USB-C to Ethernet adapter plugged into the internet box." 'DarkGray'
    }
    if ($script:Remediations.Count -and -not $Fix) {
        Write-C ""
        Write-Wrap ("Net Doctor can apply {0} safe repair(s) for you (DNS, DHCP renew, power-saving, proxy, clock, ...). Close this window and run:  NetDoctor.exe -Fix" -f $script:Remediations.Count) 'Cyan'
        Write-Wrap "To preview without changing anything:  NetDoctor.exe -Fix -DryRun" 'Cyan'
    }
}

# ----- Technical ranked list -----
Write-C ""
Write-Rule 'DarkCyan'
Write-C "  TECHNICAL NOTES  (for IT / if you need to send this to someone)" 'Cyan'
Write-Rule 'DarkCyan'
$rank=1
foreach ($grp in @(@{S='Critical';L='CRITICAL'},@{S='Warning';L='WARNINGS'},@{S='Info';L='NOTES'})) {
    $items=@($script:Findings|Where-Object Severity -eq $grp.S | Sort-Object { -$_.Priority })
    if (-not $items.Count) { continue }
    Write-C ""; Write-C "  --- $($grp.L) ---" (Get-Color $grp.S)
    foreach ($f in $items) {
        Write-C ("  {0}. [{1}] {2}" -f $rank,$f.Area,$f.Message) (Get-Color $f.Severity)
        if ($f.Recommendation) { Write-C ("      -> {0}" -f $f.Recommendation) 'Gray' }
        $rank++
    }
}

Write-C ""; Write-C "  --- MOST LIKELY CAUSE ---" 'Cyan'
$top = @($script:Findings | Where-Object { $_.Severity -in 'Critical','Warning' } | Sort-Object { -$_.Priority } | Select-Object -First 1)
if ($top) {
    $plain = if ($top.PlainWhat) { $top.PlainWhat } else { $top.Message }
    Write-Wrap $plain (Get-Color $top.Severity)
    if ($top.PlainWhy) { Write-Wrap ("Why: {0}" -f $top.PlainWhy) 'Gray' }
    if ($top.Recommendation) { Write-Wrap ("Technical action: {0}" -f $top.Recommendation) 'White' }
} else {
    Write-C "  No problems detected  - the path looks healthy end to end." 'Green'
}

# ==============================================================================
# REMEDIATION
# ==============================================================================
$rebootNeeded=$false
if ($Fix) {
    Write-C ""; Write-Rule; Write-C "  AUTO-FIX" 'Cyan'; Write-Rule
    if ($DryRun) { Write-C "  DRY RUN  - showing what would change; NOTHING is being modified." 'Yellow' }
    if (-not $script:Remediations.Count) { Write-C "  No auto-fixable issues were found. Nothing to change." 'Green' }
    else {
        foreach ($r in $script:Remediations) {
            Write-C ""; Write-C ("  * Problem : {0}" -f $r.Problem) 'Yellow'
            Write-C ("    Action  : {0}" -f $r.ActionText) 'Gray'
            $result='';$rcol='Gray'
            if ($DryRun) { $result='WOULD APPLY (dry run)'; $rcol='Cyan' }
            elseif ($r.DeepOnly -and -not $DeepFix) { $result='SKIPPED (needs -DeepFix; may require reboot)'; $rcol='DarkGray' }
            elseif (-not $isAdmin) { $result='SKIPPED (needs Administrator)'; $rcol='DarkGray' }
            else {
                try { & $r.Fix; $result='APPLIED'; $rcol='Green' } catch { $result="FAILED: $($_.Exception.Message)"; $rcol='Red' }
                if ($r.NeedsReboot -and $result -eq 'APPLIED') { $rebootNeeded=$true }
            }
            Write-C ("    Result  : {0}" -f $result) $rcol
            if ($r.Revert) { Write-C ("    Undo    : {0}" -f $r.Revert) 'DarkGray' }
            if ($r.NeedsReboot) { Write-C ("    Note    : takes effect after a reboot") 'DarkGray' }
            $script:Actions.Add([pscustomobject]@{ Time=(Get-Date).ToString('HH:mm:ss'); Area=$r.Area; Problem=$r.Problem; Action=$r.ActionText; Result=$result; Revert=$r.Revert })
        }
        if (-not $DryRun -and $isAdmin) {
            Write-C ""; Write-C "  --- Checking again after the fixes ---" 'Cyan'
            $pv=Measure-Ping -Target '8.8.8.8' -Count 4 -TimeoutMs 1500
            $dv=Measure-Dns -Name 'www.microsoft.com'
            $tv=Test-TcpTimed -Target '1.1.1.1' -Port 443 -TimeoutMs 2500
            Write-C ("  Internet ping : {0}" -f ($(if($pv.Reachable){"OK ($($pv.AvgMs) ms, $($pv.LossPct)% loss)"}else{'still DOWN'}))) $(if($pv.Reachable){'Green'}else{'Yellow'})
            Write-C ("  DNS lookup    : {0}" -f ($(if($dv.Success){"OK ($($dv.Ms) ms)"}else{'still FAILING'}))) $(if($dv.Success){'Green'}else{'Yellow'})
            Write-C ("  Web TCP/443   : {0}" -f ($(if($tv.Success){"OK ($($tv.Ms) ms)"}else{'still FAILING'}))) $(if($tv.Success){'Green'}else{'Yellow'})
        }
        if ($rebootNeeded) { Write-C ""; Write-C "  *** A RESTART of this computer is required to finish some fixes. ***" 'Yellow' }
    }
} elseif ($script:Remediations.Count) {
    Write-C ""
    Write-C ("  {0} of these issue(s) can be auto-fixed. Re-run with  -Fix  to apply (or  -Fix -DryRun  to preview)." -f $script:Remediations.Count) 'Cyan'
}

Write-C ""
$elapsed=[math]::Round(((Get-Date)-$startTime).TotalSeconds,1)
Write-C ("  Checkup finished in {0} s.  Net Doctor {1}" -f $elapsed, $script:AppVersion) 'DarkGray'

# ------------------------------------------------------------------------------
# Save report + fix log
# ------------------------------------------------------------------------------
$baseDir=$null
if ($PSScriptRoot) { $baseDir=$PSScriptRoot }
if (-not $baseDir) { try { $baseDir=Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {} }
if (-not $baseDir) { $baseDir=(Get-Location).Path }

if (-not $NoReport) {
    $stamp=(Get-Date).ToString('yyyyMMdd-HHmmss'); $fileName="NetDoctor-report-$env:COMPUTERNAME-$stamp.txt"
    $header="Net Doctor report  -  $env:COMPUTERNAME  -  $(Get-Date)  -  Mode: $modeText  -  v$script:AppVersion`r`n"+('='*78)+"`r`n"
    $savedPath=$null
    foreach ($dir in @($baseDir,$env:TEMP,[Environment]::GetFolderPath('Desktop'))) {
        if (-not $dir) { continue }
        try { $cand=Join-Path $dir $fileName; ($header+$script:Transcript.ToString())|Out-File -FilePath $cand -Encoding UTF8 -ErrorAction Stop; $savedPath=$cand; break } catch {}
    }
    Write-Host ''
    if ($savedPath) { Write-C "  Full report saved to:" 'Green'; Write-C "    $savedPath" 'White' }
    else { Write-C "  (Could not save a report  - location was read-only.)" 'Yellow' }
}

if ($Fix -and -not $DryRun -and $script:Actions.Count) {
    try {
        $logPath=Join-Path $baseDir 'NetDoctor-fixlog.txt'
        $sb=New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('='*78)
        [void]$sb.AppendLine("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  $env:COMPUTERNAME  |  user=$env:USERNAME  |  admin=$isAdmin")
        foreach ($a in $script:Actions) { [void]$sb.AppendLine(("  [{0}] {1,-8} {2}  =>  {3}" -f $a.Time,$a.Area,$a.Action,$a.Result)); if ($a.Revert) { [void]$sb.AppendLine("            undo: $($a.Revert)") } }
        Add-Content -Path $logPath -Value $sb.ToString() -Encoding UTF8 -ErrorAction Stop
        Write-C "  Changes appended to change-log:" 'Green'; Write-C "    $logPath" 'White'
    } catch { Write-C "  (Could not write the change-log file.)" 'Yellow' }
}
Write-C ""

if (-not $NoPause -and -not $env:NETDOCTOR_NOPAUSE) {
    Write-C "  Press any key to exit..." 'DarkGray'
    $paused=$false
    try { [void][System.Console]::ReadKey($true); $paused=$true } catch {}
    if (-not $paused) { try { [void](Read-Host); $paused=$true } catch {} }
    if (-not $paused) { Start-Sleep -Seconds 30 }
}
