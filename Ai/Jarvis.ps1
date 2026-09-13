#requires -version 5.1
<#
  J.A.R.V.I.S. - local desktop assistant for Windows
  - Chat UI (WPF) wired to the OpenRouter API for conversation
  - Local command engine: open/close apps, open websites, search, volume,
    lock, screenshots, battery, IP, time/date, model switching
  - API key stored locally at %APPDATA%\Jarvis\config.json
  Usage:  powershell -NoProfile -STA -ExecutionPolicy Bypass -File Jarvis.ps1
  Tests:  powershell -NoProfile -ExecutionPolicy Bypass -File Jarvis.ps1 -SelfTest
          powershell -NoProfile -STA -ExecutionPolicy Bypass -File Jarvis.ps1 -XamlTest
#>
param(
    [switch]$SelfTest,
    [switch]$XamlTest,
    [switch]$AutoDemo,
    [switch]$VoiceTest,
    [switch]$Tray
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================
#  Persistence
# ============================================================
$script:ConfigDir  = Join-Path $env:APPDATA 'Jarvis'
$script:ConfigFile = Join-Path $script:ConfigDir 'config.json'
$script:ApiKey     = $null
$script:Model      = 'openai/gpt-4o-mini'
$script:WakeWord   = $true

function Save-Config {
    try {
        if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        @{ apiKey = $script:ApiKey; model = $script:Model; wakeWord = [bool]$script:WakeWord } |
            ConvertTo-Json | Set-Content -Path $script:ConfigFile -Encoding UTF8
    } catch { }
}

function Load-Config {
    try {
        if (Test-Path $script:ConfigFile) {
            $c = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
            if ($c.apiKey)   { $script:ApiKey   = [string]$c.apiKey }
            if ($c.model)    { $script:Model    = [string]$c.model }
            if ($null -ne $c.wakeWord) { $script:WakeWord = [bool]$c.wakeWord }
        }
    } catch { }
}
Load-Config

# ============================================================
#  Installed-app scanner (Start Menu shortcuts + Store apps)
# ============================================================
$script:ScannedApps = @()

function Get-CompactName([string]$s) {
    if (-not $s) { return '' }
    return ($s.ToLower() -replace '[^a-z0-9]', '')
}

function Save-AppCache {
    try {
        if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        @($script:ScannedApps) | ConvertTo-Json -Depth 4 |
            Set-Content -Path (Join-Path $script:ConfigDir 'apps.json') -Encoding UTF8
    } catch { }
}

function Load-AppCache {
    try {
        $f = Join-Path $script:ConfigDir 'apps.json'
        if (Test-Path $f) {
            $arr = @(Get-Content $f -Raw | ConvertFrom-Json)
            $script:ScannedApps = @($arr | ForEach-Object {
                @{ name=[string]$_.name; lnk=[string]$_.lnk; exe=[string]$_.exe; kind=[string]$_.kind; appid=[string]$_.appid }
            })
        }
    } catch { $script:ScannedApps = @() }
}

function Scan-InstalledApps {
    $seen = @{}
    $dirs = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    )
    $sh = $null
    try { $sh = New-Object -ComObject WScript.Shell } catch { }
    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) { continue }
        $lnks = @(Get-ChildItem -Path $dir -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue)
        foreach ($lnk in $lnks) {
            $name = [IO.Path]::GetFileNameWithoutExtension($lnk.Name)
            $ln = $name.ToLower()
            if ($ln -match 'uninstall|readme|license|documentation|help|website|welcome') { continue }
            $exe = ''
            if ($sh) {
                try { $exe = [string]$sh.CreateShortcut($lnk.FullName).TargetPath } catch { }
            }
            if ($exe -and -not (Test-Path $exe)) { $exe = '' }
            $key = Get-CompactName $name
            if (-not $key) { continue }
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = @{ name=$name; lnk=$lnk.FullName; exe=$exe; kind='desktop'; appid='' }
            }
        }
    }
    # Registry App Paths (catches apps without Start Menu shortcuts)
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $nm = [IO.Path]::GetFileNameWithoutExtension($k.PSChildName)
            $ln2 = $nm.ToLower()
            if ($ln2 -match 'uninstall|setup|installer|update') { continue }
            $exe = ''
            try { $exe = [string](Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue).'(default)' } catch { }
            if ($exe -and -not (Test-Path $exe)) { $exe = '' }
            $key = Get-CompactName $nm
            if (-not $key -or $seen.ContainsKey($key)) { continue }
            $seen[$key] = @{ name=$nm; lnk=''; exe=$exe; kind='appath'; appid='' }
        }
    }
    try {
        $uwp = Get-StartApps -ErrorAction Stop | Where-Object { "$($_.AppID)" -match '!' }
        foreach ($u in $uwp) {
            $key = Get-CompactName ([string]$u.Name)
            if (-not $key) { continue }
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = @{ name=[string]$u.Name; lnk=''; exe=''; kind='uwp'; appid=[string]$u.AppID }
            }
        }
    } catch { }
    $script:ScannedApps = @($seen.Values)
    Save-AppCache
    return $script:ScannedApps.Count
}

function Find-ScannedApp([string]$query) {
    if (-not $script:ScannedApps -or @($script:ScannedApps).Count -eq 0) { return $null }
    $qc = Get-CompactName $query
    if (-not $qc) { return $null }
    $best = $null; $bestScore = 0; $ties = @()
    foreach ($a in @($script:ScannedApps)) {
        $nc = Get-CompactName ([string]$a.name)
        if (-not $nc) { continue }
        $score = 0
        if ($nc -eq $qc)                     { $score = 100 }
        elseif ($nc -like ($qc + '*'))       { $score = 85 }
        elseif ($nc -like ('*' + $qc + '*')) { $score = 70 }
        elseif ($nc.Length -ge 3 -and $qc -like ('*' + $nc + '*')) { $score = 55 }
        if ($score -gt $bestScore) {
            $bestScore = $score; $best = $a; $ties = @($a)
        } elseif ($score -eq $bestScore -and $score -gt 0) {
            $ties += $a
        }
    }
    if ($bestScore -lt 55) { return $null }
    return @{ app=$best; score=$bestScore; ties=@($ties) }
}

Load-AppCache

# ============================================================
#  Autostart (HKCU Run key - only affects this user)
# ============================================================
$script:RunKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'

function Get-AutoStart {
    try {
        $v = (Get-ItemProperty -Path $script:RunKey -ErrorAction SilentlyContinue).'Jarvis'
        return ($null -ne $v)
    } catch { return $false }
}

function Set-AutoStart([bool]$on) {
    try {
        if ($on) {
            $psExe = (Join-Path $PSHome 'powershell.exe')
            $cmd   = "$psExe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
            Set-ItemProperty -Path $script:RunKey -Name 'Jarvis' -Value $cmd
        } else {
            Remove-ItemProperty -Path $script:RunKey -Name 'Jarvis' -ErrorAction SilentlyContinue
        }
        return $true
    } catch { return $false }
}

# ============================================================
#  Wake-word listener ('hey Jarvis' - works even when hidden)
# ============================================================
$script:WakeRunspace = $null
$script:WakePS       = $null
$script:WakeHandle   = $null
$script:WakeTimer    = $null

function Start-WakeListener {
    if (-not $script:WakeWord) { return }
    if ($script:WakeRunspace)  { return }
    if ($script:Listening)     { return }
    try {
        Add-Type -AssemblyName System.Speech
        if ([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers().Count -eq 0) { return }
        $script:WakeRunspace = [runspacefactory]::CreateRunspace()
        $script:WakeRunspace.Open()
        $script:WakePS = [powershell]::Create()
        $script:WakePS.Runspace = $script:WakeRunspace
        # self-contained: fresh runspaces do not see this script's functions
        [void]$script:WakePS.AddScript({
            $out = @{ wake = $false; text = ''; error = $null }
            try {
                Add-Type -AssemblyName System.Speech
                $recInfo = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | Select-Object -First 1
                $reco = New-Object System.Speech.Recognition.SpeechRecognitionEngine($recInfo)
                $reco.InitialSilenceTimeout = [TimeSpan]::FromSeconds(0)
                $reco.BabbleTimeout         = [TimeSpan]::FromSeconds(0)
                $reco.EndSilenceTimeout     = [TimeSpan]::FromSeconds(0.6)
                $names  = New-Object System.Speech.Recognition.Choices
                $names.SetAll(@('hey jarvis','jarvis','jarvis you there'))
                $gbName = New-Object System.Speech.Recognition.GrammarBuilder
                $gbName.Append($names, 0, 1)
                $wakeGrammar = New-Object System.Speech.Recognition.Grammar($gbName)
                $reco.LoadGrammar($wakeGrammar)
                $reco.SetInputToDefaultAudioDevice()
                $r = $reco.Recognize([TimeSpan]::FromSeconds(25))
                $reco.UnloadAllGrammars()
                if ($r) { $out.wake = $true }
                if ($out.wake) {
                    $reco.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
                    $r2 = $reco.Recognize([TimeSpan]::FromSeconds(7))
                    if ($r2) { $out.text = [string]$r2.Text }
                }
                $reco.Dispose()
            } catch { $out.error = $_.Exception.Message }
            return $out
        })
        $script:WakeHandle = $script:WakePS.BeginInvoke()

        $script:WakeTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:WakeTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:WakeTimer.Add_Tick({
            if ($script:WakeHandle -and $script:WakeHandle.IsCompleted) {
                $res = $null
                try { $res = $script:WakePS.EndInvoke($script:WakeHandle) } catch { }
                try { $script:WakePS.Dispose() } catch { }
                try { $script:WakeRunspace.Close() } catch { }
                $script:WakeRunspace = $null; $script:WakePS = $null; $script:WakeHandle = $null

                if ($res) {
                    if ($res.wake) {
                        try { $window.Dispatcher.Invoke([Action]{ Show-Jarvis }) } catch { }
                        if ($res.text) {
                            try {
                                $window.Dispatcher.Invoke([Action]{
                                    $ui.InputBox.Text = [string]$res.text
                                    $ui.InputBox.CaretIndex = $ui.InputBox.Text.Length
                                    Submit
                                })
                            } catch { }
                        } else {
                            try { $window.Dispatcher.Invoke([Action]{ Speak "Yes, sir?" }) } catch { }
                        }
                    }
                }
                # keep the loop running (unless the mic is busy with a Voice click)
                if (-not $script:Listening) { Start-WakeListener }
            }
        })
        $script:WakeTimer.Start()
    } catch {
        try { $script:WakeTimer.Stop() } catch { }
        $script:WakeRunspace = $null; $script:WakePS = $null; $script:WakeHandle = $null
    }
}

function Stop-WakeListener {
    try { if ($script:WakeTimer) { $script:WakeTimer.Stop() } } catch { }
    try { if ($script:WakePS)    { $script:WakePS.Stop() } } catch { }
    try { if ($script:WakeRunspace) { $script:WakeRunspace.Close() } } catch { }
    $script:WakeRunspace = $null; $script:WakePS = $null; $script:WakeHandle = $null
}

function Restart-WakeListener {
    Stop-WakeListener
    Start-WakeListener
}

# Win32 key injection (volume keys, Win+H voice typing)
if (-not ([System.Management.Automation.PSTypeName]'Win.Native.Keybd').Type) {
    Add-Type -Namespace Win.Native -Name Keybd -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
'@
}

# ============================================================
#  Data maps
# ============================================================
$script:AppMap = [ordered]@{
    'notepad'             = 'notepad.exe'
    'calculator'          = 'calc.exe'
    'calc'                = 'calc.exe'
    'paint'               = 'mspaint.exe'
    'file explorer'       = 'explorer.exe'
    'explorer'            = 'explorer.exe'
    'files'               = 'explorer.exe'
    'cmd'                 = 'cmd.exe'
    'command prompt'      = 'cmd.exe'
    'terminal'            = 'wt.exe'
    'powershell'          = 'powershell.exe'
    'task manager'        = 'taskmgr.exe'
    'settings'            = 'ms-settings:'
    'chrome'              = 'chrome'
    'google chrome'       = 'chrome'
    'edge'                = 'msedge'
    'microsoft edge'      = 'msedge'
    'firefox'             = 'firefox'
    'brave'               = 'brave'
    'vscode'              = 'code'
    'vs code'             = 'code'
    'visual studio code'  = 'code'
    'code'                = 'code'
    'spotify'             = 'spotify'
    'discord'             = 'discord'
    'steam'               = 'steam'
    'word'                = 'winword'
    'excel'               = 'excel'
    'powerpoint'          = 'powerpnt'
    'outlook'             = 'outlook'
    'snipping tool'       = 'snippingtool'
}

$script:SiteMap = [ordered]@{
    'youtube'         = 'https://www.youtube.com'
    'yt'              = 'https://www.youtube.com'
    'google'          = 'https://www.google.com'
    'gmail'           = 'https://mail.google.com'
    'github'          = 'https://github.com'
    'chatgpt'         = 'https://chat.openai.com'
    'claude'          = 'https://claude.ai'
    'openrouter'      = 'https://openrouter.ai'
    'reddit'          = 'https://www.reddit.com'
    'twitter'         = 'https://twitter.com'
    'netflix'         = 'https://www.netflix.com'
    'whatsapp'        = 'https://web.whatsapp.com'
    'instagram'       = 'https://www.instagram.com'
    'facebook'        = 'https://www.facebook.com'
    'linkedin'        = 'https://www.linkedin.com'
    'amazon'          = 'https://www.amazon.com'
    'stackoverflow'   = 'https://stackoverflow.com'
    'spotify web'     = 'https://open.spotify.com'
    'maps'            = 'https://maps.google.com'
    'drive'           = 'https://drive.google.com'
    'news'            = 'https://news.google.com'
    'weather'         = 'https://www.windy.com'
    'translate'       = 'https://translate.google.com'
    'twitch'          = 'https://www.twitch.tv'
    'wikipedia'       = 'https://www.wikipedia.org'
}

$script:SearchEngines = @{
    'google'    = 'https://www.google.com/search?q={0}'
    'bing'      = 'https://www.bing.com/search?q={0}'
    'youtube'   = 'https://www.youtube.com/results?search_query={0}'
    'wikipedia' = 'https://en.wikipedia.org/w/index.php?search={0}'
    'github'    = 'https://github.com/search?q={0}'
}

$script:SystemPrompt = @'
You are JARVIS, a witty, concise personal assistant built into a Windows desktop app.
The app itself handles local commands (open apps/websites, search, volume, lock,
screenshots) which never reach you. For everything else chat: be helpful, sharp and
brief (2-4 sentences unless detail is requested). Light dry humor is welcome.
You run on Windows. Never claim to have performed local actions yourself.
'@

# ============================================================
#  Intent parsing (local commands)
# ============================================================
function Parse-Intent([string]$text) {
    $t = $text.Trim().ToLower()
    if ($t.Length -eq 0) { return $null }

    if ($t -match '^(jarvis\s+)?settings$|^(open\s+)?jarvis\s+settings$') { return @{ type='settings' } }

    if ($t -match '^(what\s+)?model(\s+are\s+you(\s+using)?)?\??$|^which\s+model(\s+are\s+you\s+using)?\??$') {
        return @{ type='which-model' }
    }
    if ($t -match '^(switch|change|set)\s+(the\s+)?model\s+(to\s+)?(.+)$') {
        return @{ type='set-model'; arg=$Matches[4].Trim() }
    }

    if ($t -match '^help$|^(what\s+can\s+you\s+do|commands)\??$') { return @{ type='help' } }
    if ($t -match '^(list|my|show( me)?|see)\s+apps(\s+(.+))?$|^apps$') {
        return @{ type='list-apps'; arg=$Matches[4] }
    }
    if ($t -match '^(rescan|scan|refresh|update)\s+(the\s+)?(my\s+)?apps$') {
        return @{ type='scan-apps' }
    }
    if ($t -match '^clear(\s+(screen|chat))?$')                   { return @{ type='clear' } }

    if ($t -match '^what.s\s+the\s+time\b|^what\s+time\s+is\s+it\b|^time\??$') { return @{ type='time' } }
    if ($t -match '^what.s\s+the\s+(date|day)\b|^date\??$')                    { return @{ type='date' } }

    if ($t -match '\bbattery\b')              { return @{ type='battery' } }
    if ($t -match '\bmy\s+ip\b|\bip\b')       { return @{ type='ip' } }
    if ($t -match 'screenshot|screen\s?shot') { return @{ type='screenshot' } }

    if ($t -match '^(mute|unmute)(\s+(the\s+)?(volume|sound))?$|^turn\s+(the\s+)?(volume|sound)\s+(up|down|off|on)$|^volume\s+(up|down|mute)$') {
        return @{ type='volume'; arg=$t }
    }

    if ($t -match '^lock\w*\s*(my\s+)?(pc|computer|windows|workstation)?$') { return @{ type='lock' } }

    if ($t -match '^(close|quit|exit|kill)\s+(.+)$') {
        $arg = $Matches[2] -replace '\s+(the\s+)?(app|application|program)$',''
        return @{ type='close'; arg=$arg.Trim() }
    }

    if ($t -match '^(play)\s+(.+?)\s+on\s+(youtube)$') {
        return @{ type='search'; arg=$Matches[2]; extra=$Matches[3] }
    }
    if ($t -match '^(search|google|youtube|bing|wikipedia|github|look\s+up)\s+(for\s+)?(.+)$') {
        $verb = $Matches[1]; $q = $Matches[3]
        if ($verb -eq 'look up') { $verb = 'google' }
        if (-not $script:SearchEngines.ContainsKey($verb)) { $verb = 'google' }
        return @{ type='search'; arg=$q; extra=$verb }
    }

    if ($t -match '^(open|launch|start|run|go\s+to|visit|show\s+me)\s+(.+)$') {
        $rest = $Matches[2]
        $rest = $rest -replace '\s+(the\s+)?(app|application|website|site|page)$',''
        return @{ type='open'; arg=$rest.Trim() }
    }

    return $null
}

# ============================================================
#  Target resolution
# ============================================================
function Resolve-Target([string]$name) {
    $n = $name.Trim().ToLower()
    if ($n -match '^(https?://|www\.)') {
        $url = if ($n -match '^https?://') { $name.Trim() } else { 'https://' + $n }
        return @{ kind='site'; value=$url; label=$name }
    }
    if ($n -match '^[a-z0-9\-]+(\.[a-z]{2,})+$') {
        return @{ kind='site'; value=('https://' + $n); label=$name }
    }

    if ($script:SiteMap.Contains($n)) { return @{ kind='site'; value=$script:SiteMap[$n]; label=$name } }

    # Real installed apps first (Start Menu / App Paths / Store), built-in map as fallback
    $scan = Find-ScannedApp $name
    if ($scan) {
        $a = $scan.app
        $val = $a.exe; if (-not $val) { $val = $a.lnk }; if (-not $val) { $val = ('shell:AppsFolder\' + $a.appid) }
        return @{ kind='scanned'; value=$val; label=$a.name; entry=$a; ties=$scan.ties }
    }
    if ($script:AppMap.Contains($n))  { return @{ kind='app';  value=$script:AppMap[$n];  label=$name } }

    foreach ($k in $script:AppMap.Keys) {
        if ($n -like "*$k*") { return @{ kind='app'; value=$script:AppMap[$k]; label=$name } }
    }
    foreach ($k in $script:SiteMap.Keys) {
        if ($k.Length -gt 2 -and $n -like "*$k*") { return @{ kind='site'; value=$script:SiteMap[$k]; label=$name } }
    }

    $candidate = $name.Trim()
    try {
        $cmd = Get-Command $candidate -ErrorAction Stop
        if ($cmd.Source) { return @{ kind='app'; value=$cmd.Source; label=$name } }
    } catch { }

    if ($candidate -match '\.(exe|lnk|bat)$' -or (Test-Path $candidate -ErrorAction SilentlyContinue)) {
        return @{ kind='app'; value=$candidate; label=$name }
    }
    return @{ kind='app'; value=$candidate; label=$name }
}

# ============================================================
#  Intent execution
# ============================================================
function Invoke-Intent([hashtable]$intent) {
    switch ($intent.type) {

        'settings' {
            Show-Settings
            return 'Opening settings.'
        }

        'which-model' {
            return "Current model: $($script:Model). Say 'switch model to <name>' to change it, or use the Settings panel."
        }

        'set-model' {
            try {
                $m = $intent.arg
                if ($m -notmatch '/') {
                    $pool = @()
                    if ($ui -and $ui.ModelBox) { $pool = @($ui.ModelBox.Items) }
                    if ($defaultModels)        { $pool = @($pool) + @($defaultModels) }
                    $known = $pool | Where-Object { $_ -like "*$m*" } | Select-Object -First 1
                    if ($known) { $m = $known }
                }
                $script:Model = $m
                if ($ui) {
                    $ui.Model   = $m
                    $ui.ModelBox.Text  = $m
                    $ui.ModelBox2.Text = $m
                }
                Save-Config
                return "Switched to $m."
            } catch { return "Couldn't switch model: $($_.Exception.Message)" }
        }

        'help' {
            return @'
Here is what I handle locally:
- open <anything>     installed apps (I scan your Start Menu), websites, or a url
- list apps           browse what I can launch; 'list apps <name>' to search
- rescan apps         re-scan installed apps
- close <app>         close chrome
- search <query>      google it (also: youtube / bing / wikipedia / github)
- volume up|down|mute
- lock                lock the workstation
- screenshot          saves to your Pictures folder
- battery / ip / time / date
- switch model to <model>
- clear               clear this window
Anything else goes to the AI.
'@
        }

        'clear' {
            $ui.Log.Children.Clear()
            return 'Cleared.'
        }

        'list-apps' {
            $list = @($script:ScannedApps)
            if ($intent.arg) {
                $m = Find-ScannedApp $intent.arg
                if ($m) { $list = @($m.ties) } else { $list = @() }
            }
            if ($list.Count -eq 0) {
                return "No apps matched '$($intent.arg)'. Say 'rescan apps' if I haven't scanned yet."
            }
            $names = @($list | Sort-Object { [string]$_.name } | ForEach-Object { [string]$_.name })
            $shown = @($names | Select-Object -First 40)
            $out = "I know $($script:ScannedApps.Count) installed apps:"
            if ($intent.arg) { $out = "Apps matching '$($intent.arg)':" }
            $out += "`n" + (($shown | ForEach-Object { "- $_" }) -join "`n")
            if ($names.Count -gt 40) { $out += "`n... and $($names.Count - 40) more. Use 'list apps <name>' to search."
            }
            return $out
        }

        'scan-apps' {
            $n = Scan-InstalledApps
            return "Scan complete - I can now open $n installed apps. Try 'list apps' or 'open <name>'."
        }

        'time' { return ('It is ' + (Get-Date -Format 'h:mm tt') + '.') }
        'date' { return ('Today is ' + (Get-Date -Format 'dddd, MMMM d, yyyy') + '.') }

        'battery' {
            try {
                $b = Get-CimInstance Win32_Battery -ErrorAction Stop
                if ($b) { return ('Battery is at ' + [int]$b.EstimatedChargeRemaining + '%.') }
            } catch { }
            return 'No battery detected - you are probably on a desktop.'
        }

        'ip' {
            try {
                $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
                return "Your public IP is $ip."
            } catch { return 'I could not reach the IP lookup service.' }
        }

        'screenshot' {
            try {
                Add-Type -AssemblyName System.Drawing
                Add-Type -AssemblyName System.Windows.Forms
                $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
                $dir = [Environment]::GetFolderPath('MyPictures')
                $path = Join-Path $dir ('Jarvis_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png')
                $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
                $g.Dispose(); $bmp.Dispose()
                return "Screenshot saved to $path"
            } catch { return 'Screenshot failed: ' + $_.Exception.Message }
        }

        'volume' {
            $a = $intent.arg
            if ($a -match 'mute|off') {
                [Win.Native.Keybd]::keybd_event(0xAD,0,0,[UIntPtr]::Zero); [Win.Native.Keybd]::keybd_event(0xAD,0,2,[UIntPtr]::Zero)
                return 'Muted.'
            } elseif ($a -match 'unmute|on') {
                [Win.Native.Keybd]::keybd_event(0xAD,0,0,[UIntPtr]::Zero); [Win.Native.Keybd]::keybd_event(0xAD,0,2,[UIntPtr]::Zero)
                return 'Toggled mute.'
            } elseif ($a -match 'up') {
                1..5 | ForEach-Object { [Win.Native.Keybd]::keybd_event(0xAF,0,0,[UIntPtr]::Zero); [Win.Native.Keybd]::keybd_event(0xAF,0,2,[UIntPtr]::Zero) }
                return 'Volume up.'
            } elseif ($a -match 'down') {
                1..5 | ForEach-Object { [Win.Native.Keybd]::keybd_event(0xAE,0,0,[UIntPtr]::Zero); [Win.Native.Keybd]::keybd_event(0xAE,0,2,[UIntPtr]::Zero) }
                return 'Volume down.'
            }
            return $null
        }

        'lock' {
            Start-Process rundll32.exe -ArgumentList 'user32.dll,LockWorkStation'
            return 'Locking.'
        }

        'close' {
            $n = $intent.arg
            if ($n -match 'everything|all') {
                return "I only close apps by name - tell me which one, for example: close chrome"
            }
            $resolved = Resolve-Target $n
            if ($resolved.kind -eq 'site') { return "That is a website, not an app. Close the browser instead, e.g. 'close edge'." }
            if ($resolved.kind -eq 'scanned' -and $resolved.entry.kind -eq 'uwp') {
                return "Store apps are tricky to close by name - use Task View or Alt+Tab for that one."
            }
            $procName = [IO.Path]::GetFileNameWithoutExtension($resolved.value)
            $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
            if ($procs.Count -eq 0) { return "I don't see $n running." }
            $closed = 0
            foreach ($p in $procs) {
                try { if ($p.CloseMainWindow()) { $closed++ } } catch { }
            }
            Start-Sleep -Milliseconds 1200
            foreach ($p in (Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
                try { $p | Stop-Process -Force; $closed++ } catch { }
            }
            return "Closed $n ($closed window(s)/process(es))."
        }

        'search' {
            $engine = $intent.extra
            if (-not $script:SearchEngines.ContainsKey($engine)) { $engine = 'google' }
            $url = $script:SearchEngines[$engine] -f [uri]::EscapeDataString($intent.arg)
            Start-Process $url
            return "Searching $engine for '$($intent.arg)'."
        }

        'open' {
            $t = Resolve-Target $intent.arg
            try {
                if ($t.kind -eq 'scanned') {
                    $a = $t.entry
                    if (@($t.ties).Count -gt 1) {
                        $names = (@($t.ties | Select-Object -First 6 | ForEach-Object { [string]$_.name }) -join ', ')
                        return "I found $($t.ties.Count) apps matching that: $names. Say 'open <full name>' for the one you want."
                    }
                    if ($a.kind -eq 'uwp') {
                        $shellTarget = 'shell:AppsFolder\' + $a.appid
                        try { Start-Process $shellTarget }
                        catch { Start-Process explorer.exe -ArgumentList $shellTarget }
                        return "Launching $($a.name)."
                    }
                    if ($a.lnk) { Start-Process $a.lnk } else { Start-Process $a.exe }
                    return "Launching $($a.name)."
                }
                Start-Process $t.value
                if ($t.kind -eq 'site') { return "Opening $($t.label)." }
                return "Launching $($t.label)."
            } catch {
                return "I couldn't find anything called '$($t.label)'. Try 'help' to see what I know."
            }
        }
    }
    return $null
}

# ============================================================
#  Self test (no UI)
# ============================================================
if ($SelfTest) {
    $samples = @(
        'open chrome', 'open youtube', 'open github.com', 'open file explorer',
        'open the settings', 'close chrome', 'search latest ai news', 'youtube lofi beats',
        'play lofi beats on youtube', 'volume up', 'mute', 'lock', 'screenshot', 'battery',
        'my ip', 'what time is it', "what's the date", 'what model are you',
        'switch model to anthropic/claude-3.5-haiku', 'help', 'clear',
        'settings', 'what is the meaning of life'
    )
    $fail = 0
    foreach ($s in $samples) {
        $i = Parse-Intent $s
        if ($i) {
            $desc = $i.type
            if ($i.arg)   { $desc += (" arg='" + $i.arg + "'") }
            if ($i.extra) { $desc += (" extra='" + $i.extra + "'") }
            Write-Output ("{0,-45} -> {1}" -f $s, $desc)
        } else {
            Write-Output ("{0,-45} -> (AI)" -f $s)
        }
    }

    # assertions
    $checks = @(
        @{ s='open chrome';        expect='open';      argLike='chrome' },
        @{ s='open youtube';       expect='open';      argLike='youtube' },
        @{ s='close chrome';       expect='close';     argLike='chrome' },
        @{ s='volume up';          expect='volume' },
        @{ s='lock';               expect='lock' },
        @{ s='screenshot';         expect='screenshot' },
        @{ s='what time is it';    expect='time' },
        @{ s='search ai news';     expect='search';    extraLike='google' },
        @{ s='settings';           expect='settings' },
        @{ s='list apps';          expect='list-apps' },
        @{ s='show me apps';       expect='list-apps' },
        @{ s='list apps spotify';  expect='list-apps'; argLike='spotify' },
        @{ s='rescan apps';        expect='scan-apps' },
        @{ s='tell me a joke';     expect=$null }
    )
    foreach ($c in $checks) {
        $i = Parse-Intent $c.s
        $ok = $true
        if ($c.expect -eq $null) { $ok = ($null -eq $i) }
        else {
            $ok = ($i -and $i.type -eq $c.expect)
            if ($ok -and $c.argLike)   { $ok = ($i.arg   -like ("*" + $c.argLike + "*")) }
            if ($ok -and $c.extraLike) { $ok = ($i.extra -like ("*" + $c.extraLike + "*")) }
        }
        if (-not $ok) { $fail++; Write-Output ("FAIL: '{0}'" -f $c.s) }
    }

    $r  = Resolve-Target 'youtube'
    if ($r.kind -ne 'site') { $fail++; Write-Output "FAIL: resolve youtube should be site" }
    $r2 = Resolve-Target 'notepad'
    if (($r2.kind -ne 'app' -and $r2.kind -ne 'scanned') -or -not $r2.value) { $fail++; Write-Output "FAIL: resolve notepad should be app/scanned with a value" }
    $r3 = Resolve-Target 'example.com'
    if ($r3.kind -ne 'site') { $fail++; Write-Output "FAIL: resolve example.com should be site" }

    # app-scanner matching
    $script:ScannedApps = @(
        @{ name='Spotify';       lnk='C:\x\Spotify.lnk'; exe='C:\x\Spotify.exe'; kind='desktop'; appid='' },
        @{ name='Google Chrome'; lnk='';                 exe='C:\x\chrome.exe';  kind='desktop'; appid='' },
        @{ name='Calculator';    lnk='';                 exe='';                 kind='uwp'; appid='Microsoft.WindowsCalculator_8wekyb3d8bbwe!App' }
    )
    $m1 = Find-ScannedApp 'spotify'
    if (-not $m1 -or $m1.app.name -ne 'Spotify')       { $fail++; Write-Output 'FAIL: scan match spotify' }
    $m2 = Find-ScannedApp 'chrome'
    if (-not $m2 -or $m2.app.name -ne 'Google Chrome') { $fail++; Write-Output 'FAIL: scan match chrome' }
    $m3 = Find-ScannedApp 'calculator'
    if (-not $m3 -or $m3.app.kind -ne 'uwp')           { $fail++; Write-Output 'FAIL: scan match calculator' }
    $m4 = Find-ScannedApp 'zzznothing'
    if ($m4) { $fail++; Write-Output 'FAIL: scan non-match should be null' }

    if ($fail -gt 0) { Write-Output "SELF-TEST FAILED: $fail failure(s)"; exit 1 }
    Write-Output 'SELF-TEST PASSED'
    exit 0
}

# ============================================================
#  UI
# ============================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$xamlRaw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="J.A.R.V.I.S." Height="640" Width="880" MinHeight="480" MinWidth="620"
        WindowStartupLocation="CenterScreen" Background="#FF05070D" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#FF101A2C"/>
      <Setter Property="Foreground" Value="#FFD9E4F5"/>
      <Setter Property="BorderBrush" Value="#FF22304C"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF172742"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#FF2E4368"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border BorderBrush="#FF1B2438" BorderThickness="1" CornerRadius="8" Background="#FF0A0E18">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Header -->
      <Border Grid.Row="0" Background="#FF0D1322" Padding="14,10" BorderBrush="#FF1B2438" BorderThickness="0,0,0,1">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Grid x:Name="StatusDot" Grid.Column="0" Width="12" Height="12" VerticalAlignment="Center" Margin="0,0,10,0">
            <Grid.Effect><DropShadowEffect Color="#FF40E0D0" BlurRadius="16" ShadowDepth="0"/></Grid.Effect>
          </Grid>
          <TextBlock x:Name="StatusText" Grid.Column="1" Text="ONLINE" Foreground="#FF40E0D0"
                     FontSize="11" VerticalAlignment="Center" Margin="0,0,18,0"/>
          <TextBlock Grid.Column="2" Text="J A R V I S" Foreground="#FFF0B429" FontSize="18"
                     FontWeight="Bold" VerticalAlignment="Center" HorizontalAlignment="Center"/>
          <ComboBox x:Name="ModelBox" Grid.Column="3" Width="230" Height="26" VerticalAlignment="Center"
                    IsEditable="True" Background="#FF0D1524" BorderBrush="#FF22304C"
                    Foreground="#FFD9E4F5" FontSize="11" ToolTip="OpenRouter model id"/>
          <Button x:Name="KeyBtn" Grid.Column="4" Content="API Key" Width="70" Height="26"
                  Margin="8,0,0,0" Style="{StaticResource Btn}"/>
          <Button x:Name="HelpBtn" Grid.Column="5" Content="?" Width="26" Height="26"
                  Margin="8,0,0,0" Style="{StaticResource Btn}"/>
        </Grid>
      </Border>

      <!-- Blueprint grid + chat log -->
      <Grid Grid.Row="1" Background="#FF04070E">
        <Grid x:Name="GridGlow" Opacity="0.55">
          <Grid.Background>
            <DrawingBrush TileMode="Tile" Viewport="0,0,44,44" ViewportUnits="Absolute">
              <DrawingBrush.Drawing>
                <GeometryDrawing Geometry="M0,0 L44,0 M0,0 L0,44">
                  <GeometryDrawing.Pen>
                    <Pen Brush="#FF142036" Thickness="1"/>
                  </GeometryDrawing.Pen>
                </GeometryDrawing>
              </DrawingBrush.Drawing>
            </DrawingBrush>
          </Grid.Background>
        </Grid>
        <ScrollViewer x:Name="Scroller" VerticalScrollBarVisibility="Auto" Padding="18,14,10,8">
          <StackPanel x:Name="Log"/>
        </ScrollViewer>
      </Grid>

      <!-- Input row -->
      <Border Grid.Row="2" Background="#FF0A0F1B" BorderBrush="#FF1B2438" BorderThickness="0,1,0,0" Padding="12,10">
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="InputBox" Height="64" AcceptsReturn="True" TextWrapping="Wrap"
                     Background="#FF0D1524" Foreground="#FFD9E4F5" BorderBrush="#FF22304C"
                     CaretBrush="#FFF0B429" Padding="8,6" VerticalScrollBarVisibility="Auto"
                     FontSize="13"/>
            <StackPanel Grid.Column="1" Margin="8,0,0,0">
              <Button x:Name="SendBtn" Content="Send" Width="92" Height="30" Style="{StaticResource Btn}"/>
              <Button x:Name="MicBtn" Content="Voice" Width="92" Height="30" Margin="0,6,0,0" Style="{StaticResource Btn}"
                      ToolTip="Speak a command - JARVIS transcribes it in-app and acts. Falls back to Windows voice typing if the mic engine fails."/>
            </StackPanel>            </Grid>
            <TextBlock x:Name="MicStatus" Text="" Foreground="#FF40E0D0" FontSize="11" Margin="0,5,0,0"
                       Visibility="Collapsed" TextWrapping="Wrap"/>
            <TextBlock x:Name="Hint" Foreground="#FF44546E" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap"
                     Text="Enter to send - Shift+Enter for newline - try: open chrome / open youtube / close chrome / search ai news / volume up / lock / battery / what time is it"/>
        </StackPanel>
      </Border>

      <!-- Settings overlay -->
      <Border x:Name="SettingsPanel" Grid.Row="0" Grid.RowSpan="3" Background="#C005070D" Visibility="Collapsed">
        <Border Width="580" Height="430" Background="#FF0D1322" BorderBrush="#FF22304C"
                BorderThickness="1" CornerRadius="10" Padding="22">
          <StackPanel>
            <TextBlock Text="SETTINGS" Foreground="#FFF0B429" FontSize="18" FontWeight="Bold" Margin="0,0,0,14"/>
            <TextBlock Text="OpenRouter API key" Foreground="#FFD9E4F5" FontSize="12" Margin="0,0,0,4"/>
            <PasswordBox x:Name="KeyBox" Height="30" Background="#FF0D1524" Foreground="#FFD9E4F5"
                         BorderBrush="#FF22304C" Padding="6,4" CaretBrush="#FFF0B429"/>
            <TextBlock Text="Model" Foreground="#FFD9E4F5" FontSize="12" Margin="0,12,0,4"/>
            <ComboBox x:Name="ModelBox2" Height="30" IsEditable="True" Background="#FF0D1524"
                      BorderBrush="#FF22304C" Foreground="#FFD9E4F5"/>
            <CheckBox x:Name="AutoStartCheck" Content="Start JARVIS automatically when Windows starts" Foreground="#FFD9E4F5" FontSize="12" Margin="0,16,0,0"/>
            <CheckBox x:Name="WakeWordCheck" Content="Wake word: say &quot;hey Jarvis&quot; anytime to summon me (listens in background)" Foreground="#FFD9E4F5" FontSize="12" Margin="0,8,0,0"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
              <Button x:Name="SaveBtn" Content="Save" Width="96" Height="30" Style="{StaticResource Btn}"/>
              <Button x:Name="CancelBtn" Content="Cancel" Width="96" Height="30" Margin="10,0,0,0" Style="{StaticResource Btn}"/>
            </StackPanel>
            <TextBlock x:Name="SettingsMsg" Text="" Foreground="#FF7EF0B2" FontSize="12" Margin="0,12,0,0" TextWrapping="Wrap"/>
            <TextBlock Foreground="#FF44546E" FontSize="11" Margin="0,14,0,0" TextWrapping="Wrap"
                       Text="Get a free key at openrouter.ai/keys (many models have free tiers). The key is stored locally only: %APPDATA%\Jarvis\config.json"/>
          </StackPanel>
        </Border>
      </Border>
    </Grid>
  </Border>
</Window>
'@

if ($XamlTest) {
    try {
        $null = [System.Windows.Markup.XamlReader]::Parse($xamlRaw)
        Write-Output 'XAML-TEST PASSED'
        exit 0
    } catch {
        Write-Output ("XAML-TEST FAILED: " + $_.Exception.Message)
        exit 1
    }
}

$window = [System.Windows.Markup.XamlReader]::Parse($xamlRaw)

# Map every x:Name element into the $ui hashtable
$ui = @{}
$xdoc = New-Object System.Xml.XmlDocument
$xdoc.LoadXml($xamlRaw)
$ns = New-Object System.Xml.XmlNamespaceManager($xdoc.NameTable)
$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
foreach ($node in $xdoc.SelectNodes('//*[@x:Name]', $ns)) {
    $ui[$node.Name] = $window.FindName($node.Name)
}

$defaultModels = @(
    'openai/gpt-4o-mini',
    'openai/gpt-4.1-mini',
    'anthropic/claude-3.5-haiku',
    'google/gemini-2.0-flash-001',
    'meta-llama/llama-3.3-70b-instruct',
    'deepseek/deepseek-chat',
    'mistralai/mistral-small-24b-instruct-2501'
)
foreach ($m in $defaultModels) {
    [void]$ui.ModelBox.Items.Add($m)
    [void]$ui.ModelBox2.Items.Add($m)
}

$ui.Inbox        = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
$ui.Kill         = $false
$ui.ApiKey       = $script:ApiKey
$ui.Model        = $script:Model
$ui.SystemPrompt = $script:SystemPrompt
$ui.Populating   = $false

function Set-Status([string]$text, [string]$hex) {
    $ui.StatusText.Text = $text
    try {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
        $ui.StatusDot.Fill = New-Object System.Windows.Media.SolidColorBrush $color
        $ui.StatusText.Foreground = New-Object System.Windows.Media.SolidColorBrush $color
    } catch { }
}

function Add-Message([string]$who, [string]$text) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = New-Object System.Windows.Thickness 0,3,0,3
    $w = New-Object System.Windows.Documents.Run ("$who  ")
    if ($who -eq 'You') {
        $w.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF7FD4FF'))
    } else {
        $w.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFF0B429'))
    }
    $w.FontWeight = 'Bold'
    [void]$tb.Inlines.Add($w)
    $parts = ($text -replace "`r", '') -split "`n"
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -gt 0) { [void]$tb.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) }
        $r = New-Object System.Windows.Documents.Run $parts[$i]
        $r.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFD9E4F5'))
        [void]$tb.Inlines.Add($r)
    }
    [void]$ui.Log.Children.Add($tb)
    $ui.Scroller.ScrollToEnd()
}

$script:TtsVoiceName = 'Microsoft David Desktop'
try {
    Add-Type -AssemblyName System.Speech
    $probe = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $male = @($probe.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Gender -eq [System.Speech.Synthesis.VoiceGender]::Male } | Select-Object -First 1)
    if ($male) { $script:TtsVoiceName = $male.VoiceInfo.Name }
    $probe.Dispose()
} catch { }

function Speak([string]$text) {
    if ($script:MuteTTS) { return }
    try {
        if (-not $script:TTS) {
            Add-Type -AssemblyName System.Speech
            $script:TTS = New-Object System.Speech.Synthesis.SpeechSynthesizer
            try { $script:TTS.SelectVoice($script:TtsVoiceName) } catch { }
            $script:TTS.Rate = 1
        }
        $short = ($text -split "`n")[0]
        if ($short.Length -gt 220) { $short = $short.Substring(0,220) }
        [void]$script:TTS.SpeakAsync($short)
    } catch { }
}

function Show-Jarvis {
    try {
        $window.Show()
        $window.WindowState    = 'Normal'
        $window.ShowInTaskbar  = $true
        $window.Activate()
        [void]$ui.InputBox.Focus()
        Stop-Speaking
    } catch { }
}

function Hide-To-Tray {
    try {
        $window.Hide()
        $window.ShowInTaskbar = $false
    } catch { }
}

function Stop-Speaking {
    try { if ($script:TTS) { $script:TTS.SpeakAsyncCancelAll() } } catch { }
}

# ============================================================
#  In-app speech recognition (System.Speech, offline engine)
# ============================================================
function Test-VoiceEngine {
    try {
        Add-Type -AssemblyName System.Speech
        $recs = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
        return ($recs.Count -gt 0)
    } catch { return $false }
}

function Start-Dictation {
    $result = @{ text = ''; error = $null }
    try {
        Add-Type -AssemblyName System.Speech
        $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine
        $recInfo = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | Select-Object -First 1
        $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine($recInfo)
        $recognizer.InitialSilenceTimeout = [TimeSpan]::FromSeconds(6)
        $recognizer.BabbleTimeout         = [TimeSpan]::FromSeconds(3)
        $recognizer.EndSilenceTimeout    = [TimeSpan]::FromSeconds(1.2)

        $grammar = New-Object System.Speech.Recognition.DictationGrammar
        $recognizer.LoadGrammar($grammar)

        $recognizer.SetInputToDefaultAudioDevice()
        $res = $recognizer.Recognize([TimeSpan]::FromSeconds(9))
        $recognizer.UnloadAllGrammars()
        $recognizer.Dispose()
        if ($res) { $result.text = [string]$res.Text } else { $result.error = "I didn't catch that - try holding the button, speaking, then releasing." }
    } catch {
        $result.error = $_.Exception.Message
    }
    return $result
}

function Show-Settings {
    $ui.KeyBox.Clear()
    $ui.ModelBox2.Text = $script:Model
    $ui.AutoStartCheck.IsChecked = Get-AutoStart
    $ui.WakeWordCheck.IsChecked  = $script:WakeWord
    $ui.SettingsMsg.Text = ''
    $ui.SettingsMsg.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF7EF0B2'))
    $ui.SettingsPanel.Visibility = 'Visible'
    if (-not $ui.ModelsRequested) {
        $ui.ModelsRequested = $true
        $ui.Inbox.Enqueue(@{ kind='fetchmods' })
    }
}

function Submit {
    $text = $ui.InputBox.Text.Trim()
    if (-not $text) { return }
    $ui.InputBox.Clear()
    Add-Message 'You' $text

    $intent = Parse-Intent $text
    if ($intent) {
        try {
            $out = Invoke-Intent $intent
        } catch {
            $out = 'That local command failed: ' + $_.Exception.Message
        }
        if ($out) {
            Add-Message 'JARVIS' $out
            Speak $out
            return
        }
    }
    $ui.Inbox.Enqueue(@{ kind='chat'; text=$text })
    Set-Status 'THINKING' '#FFF0B429'
}

# Delegates the worker thread uses to touch the UI safely
$ui.PostMessage = [Action[string,string]]{
    param($who, $text)
    try { $window.Dispatcher.Invoke([Action]{ Add-Message $who $text }) } catch { }
}
$ui.PostStatus = [Action[string,string]]{
    param($t, $c)
    try { $window.Dispatcher.Invoke([Action]{ Set-Status $t $c }) } catch { }
}

# ============================================================
#  Worker runspace (OpenRouter calls, off the UI thread)
# ============================================================
$workerScript = {
    function Worker-Chat([string]$text) {
        $key   = $ui.ApiKey
        $model = $ui.Model
        if (-not $key) {
            $ui.PostMessage.Invoke('JARVIS', 'No API key set. Click "API Key" in the top bar and paste your OpenRouter key (openrouter.ai/keys).')
            return
        }
        $ui.PostStatus.Invoke('THINKING', '#FFF0B429')
        try {
            $body = @{
                model = $model
                messages = @(
                    @{ role='system'; content=$ui.SystemPrompt },
                    @{ role='user';   content=$text }
                )
                temperature = 0.7
            } | ConvertTo-Json -Depth 8
            $headers = @{
                'Authorization' = "Bearer $key"
                'Content-Type'  = 'application/json'
                'HTTP-Referer'  = 'https://jarvis.local'
                'X-Title'       = 'Jarvis Desktop'
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $resp = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/chat/completions' `
                -Method Post -Headers $headers -Body $bytes -TimeoutSec 90
            $reply = [string]$resp.choices[0].message.content
            $reply = $reply -replace '\*\*(.+?)\*\*','$1'
            $reply = ($reply -split "`n" | ForEach-Object { $_ -replace '^#+\s*','' }) -join "`n"
            $ui.PostMessage.Invoke('JARVIS', $reply)
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match '401')     { $msg = 'OpenRouter rejected the API key (401). Click API Key and re-check it.' }
            elseif ($msg -match '402') { $msg = 'OpenRouter says this key has no credits (402). Add credits or pick a free model.' }
            elseif ($msg -match '429') { $msg = 'Rate limited by OpenRouter (429). Wait a moment and try again.' }
            $ui.PostMessage.Invoke('JARVIS', "Request failed: $msg")
        } finally {
            $ui.PostStatus.Invoke('ONLINE', '#FF40E0D0')
        }
    }

    function Worker-SaveKey([string]$key, [string]$model) {
        $ui.PostStatus.Invoke('CHECKING', '#FFF0B429')
        try {
            $h = @{ 'Authorization' = "Bearer $key" }
            $resp = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/key' -Headers $h -TimeoutSec 20
            $ui.SaveResult = @{ ok = $true; key = $key; model = $model; label = [string]$resp.data.label }
        } catch {
            $m = $_.Exception.Message
            if ($m -match '401') { $m = 'Invalid key (401).' }
            $ui.SaveResult = @{ ok = $false; error = $m }
        } finally {
            $ui.PostStatus.Invoke('ONLINE', '#FF40E0D0')
        }
    }

    function Worker-FetchModels {
        try {
            $resp = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/models' -TimeoutSec 25
            $ids = @($resp.data | ForEach-Object { $_.id } | Select-Object -First 400)
            $ui.FetchedModels = $ids
        } catch { }
    }

    while (-not $ui.Kill) {
        try {
            $item = $null
            if ($ui.Inbox.TryDequeue([ref]$item)) {
                switch ($item.kind) {
                    'chat'      { Worker-Chat $item.text }
                    'savekey'   { Worker-SaveKey $item.key $item.model }
                    'fetchmods' { Worker-FetchModels }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 60
    }
}

$script:RunspaceWorker = [runspacefactory]::CreateRunspace()
$script:RunspaceWorker.Open()
$script:RunspaceWorker.SessionStateProxy.SetVariable('ui', $ui)
$script:PSWorker = [powershell]::Create()
$script:PSWorker.Runspace = $script:RunspaceWorker
[void]$script:PSWorker.AddScript($workerScript)
$ui.PSHandle = $script:PSWorker.BeginInvoke()

# ============================================================
#  Event wiring
# ============================================================
$ui.SendBtn.Add_Click({ Submit })
$ui.HelpBtn.Add_Click({
    Add-Message 'JARVIS' (Invoke-Intent @{ type='help' })
})
$ui.InputBox.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter -and
        -not (($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Shift))) {
        $e.Handled = $true
        Submit
    }
})

$ui.MicBtn.Add_Click({
    if ($script:Listening) { return }
    if (-not (Test-VoiceEngine)) {
        # Offline engine unavailable -> fall back to Windows voice typing (Win+H)
        try {
            [Win.Native.Keybd]::keybd_event(0x5B,0,0,[UIntPtr]::Zero)
            [Win.Native.Keybd]::keybd_event(0x48,0,0,[UIntPtr]::Zero)
            [Win.Native.Keybd]::keybd_event(0x48,0,2,[UIntPtr]::Zero)
            [Win.Native.Keybd]::keybd_event(0x5B,0,2,[UIntPtr]::Zero)
        } catch { }
        return
    }
    $script:Listening = $true
    Stop-Speaking
    Stop-WakeListener   # free the mic for dictation
    $ui.MicBtn.Content = 'Listening...'
    $ui.MicBtn.IsEnabled = $false
    $ui.MicStatus.Text = 'Listening - speak now...'
    $ui.MicStatus.Visibility = 'Visible'
    $ui.MicStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF40E0D0'))

    # run recognition on a background thread so the UI stays responsive.
    # Hybrid accuracy strategy: a precision grammar built from the user's real
    # app/site/command vocabulary is tried first; free dictation is the fallback.
    $vocab = @()
    foreach ($a in @($script:ScannedApps)) { $vocab += [string]$a.name }
    $vocab += @($script:AppMap.Keys) + @($script:SiteMap.Keys)
    $vocab = @($vocab | Where-Object { $_ -and $_.Length -ge 2 } | Select-Object -Unique -First 300)

    $script:VoiceRunspace = [runspacefactory]::CreateRunspace()
    $script:VoiceRunspace.Open()
    $script:VoicePS = [powershell]::Create()
    $script:VoicePS.Runspace = $script:VoiceRunspace
    [void]$script:VoicePS.AddScript({
        param($vocabList)
        $out = @{ text = ''; error = $null; via = '' }
        try {
            Add-Type -AssemblyName System.Speech
            $recInfo = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | Select-Object -First 1
            $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine($recInfo)
            $recognizer.InitialSilenceTimeout = [TimeSpan]::FromSeconds(5)
            $recognizer.BabbleTimeout         = [TimeSpan]::FromSeconds(2)
            $recognizer.EndSilenceTimeout    = [TimeSpan]::FromSeconds(1.2)
            $recognizer.SetInputToDefaultAudioDevice()

            # 1) precision pass: fixed phrases + open/close <app/site>
            try {
                $fixed = @('what time is it','what is the date','battery','my ip','lock','mute','unmute','volume up','volume down','screenshot','help','list apps','rescan apps','settings','clear','stop speaking')
                $verbsOpen  = New-Object System.Speech.Recognition.GrammarBuilder; $verbsOpen.Append('open')
                $verbsClose = New-Object System.Speech.Recognition.GrammarBuilder; $verbsClose.Append('close')
                if ($vocabList -and @($vocabList).Count -gt 0) {
                    $choices = New-Object System.Speech.Recognition.Choices
                    $choices.SetAll([string[]]@($vocabList))
                    $targets = New-Object System.Speech.Recognition.GrammarBuilder
                    $targets.Append($choices, 0, 1)
                    $verbsOpen.Append($targets, 0, 1)
                    $verbsClose.Append($targets, 0, 1)
                }
                $allPhrases = New-Object System.Collections.Generic.List[string]
                foreach ($p in $fixed) { [void]$allPhrases.Add($p) }
                $gFixed = New-Object System.Speech.Recognition.Choices
                $gFixed.SetAll([string[]]$allPhrases)
                $gbFixed = New-Object System.Speech.Recognition.GrammarBuilder
                $gbFixed.Append($gFixed, 0, 1)
                $gbOpen  = New-Object System.Speech.Recognition.GrammarBuilder; $gbOpen.Append(($verbsOpen), 0, 1)
                $gbClose = New-Object System.Speech.Recognition.GrammarBuilder; $gbClose.Append(($verbsClose), 0, 1)
                # load three alternative grammars; Recognize matches any of them
                $recognizer.LoadGrammar((New-Object System.Speech.Recognition.Grammar($gbFixed)))
                $recognizer.LoadGrammar((New-Object System.Speech.Recognition.Grammar($gbOpen)))
                $recognizer.LoadGrammar((New-Object System.Speech.Recognition.Grammar($gbClose)))
                $res = $recognizer.Recognize([TimeSpan]::FromSeconds(8))
                if ($res -and $res.Confidence -ge 0.55) {
                    $out.text = ([string]$res.Text).Trim()
                    $out.via  = 'grammar'
                }
            } catch { }

            # 2) dictation fallback for free-form text
            if (-not $out.text) {
                $dict = New-Object System.Speech.Recognition.DictationGrammar
                $recognizer.UnloadAllGrammars()
                $recognizer.LoadGrammar($dict)
                $res2 = $recognizer.Recognize([TimeSpan]::FromSeconds(8))
                if ($res2 -and $res2.Confidence -ge 0.45) {
                    $out.text = ([string]$res2.Text).Trim()
                    $out.via  = 'dictation'
                }
            }
            $recognizer.Dispose()
            if (-not $out.text) { $out.error = "I didn't catch that, sir. Click Voice and speak clearly - or type it." }
        } catch {
            $out.error = $_.Exception.Message
        }
        return $out
    }).AddArgument([string[]]$vocab)
    $script:VoiceHandle = $script:VoicePS.BeginInvoke()

    $script:VoiceTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:VoiceTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:VoiceTimer.Add_Tick({
        if ($script:VoiceHandle -and $script:VoiceHandle.IsCompleted) {
            try { $script:VoiceTimer.Stop() } catch { }
            $res = $null
            try { $res = $script:VoicePS.EndInvoke($script:VoiceHandle) } catch { }
            try { $script:VoicePS.Dispose() } catch { }
            try { $script:VoiceRunspace.Close() } catch { }
            $script:VoicePS = $null; $script:VoiceHandle = $null

            $script:Listening = $false
            $ui.MicBtn.Content = 'Voice'
            $ui.MicBtn.IsEnabled = $true
            $ui.MicStatus.Visibility = 'Collapsed'
            if ($script:WakeWord) { Start-WakeListener }   # hand the mic back

            $text = ''; $err = $null
            if ($res) { $text = [string]$res.text; $err = $res.error }
            if ($text) {
                $ui.InputBox.Text = $text
                $ui.InputBox.CaretIndex = $ui.InputBox.Text.Length
                Submit
            } elseif ($err) {
                $ui.MicStatus.Text = $err
                $ui.MicStatus.Visibility = 'Visible'
                $ui.MicStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFF7B72'))
                $script:MicHideTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:MicHideTimer.Interval = [TimeSpan]::FromSeconds(5)
                $script:MicHideTimer.Add_Tick({
                    try { $script:MicHideTimer.Stop() } catch { }
                    $ui.MicStatus.Visibility = 'Collapsed'
                })
                $script:MicHideTimer.Start()
            }
        }
    })
    $script:VoiceTimer.Start()
})

function Sync-ModelFrom([string]$text) {
    if ($ui.Populating) { return }
    $t = $text.Trim()
    if ($t -and $t -ne $script:Model) {
        $script:Model = $t
        $ui.Model = $t
        Save-Config
    }
}
$ui.ModelBox.Add_SelectionChanged({
    param($s, $e)
    Sync-ModelFrom $ui.ModelBox.Text
    $ui.ModelBox2.Text = $ui.ModelBox.Text
})
$ui.ModelBox.Add_LostFocus({
    param($s, $e)
    Sync-ModelFrom $ui.ModelBox.Text
})
$ui.ModelBox2.Add_SelectionChanged({
    param($s, $e)
    Sync-ModelFrom $ui.ModelBox2.Text
    $ui.ModelBox.Text = $ui.ModelBox2.Text
})
$ui.ModelBox2.Add_LostFocus({
    param($s, $e)
    Sync-ModelFrom $ui.ModelBox2.Text
})

$ui.KeyBtn.Add_Click({ Show-Settings })
$ui.CancelBtn.Add_Click({ $ui.SettingsPanel.Visibility = 'Collapsed' })
$ui.SaveBtn.Add_Click({
    # settings toggles apply immediately
    $wantAuto = [bool]$ui.AutoStartCheck.IsChecked
    $autoOk = Set-AutoStart $wantAuto
    $newWake = [bool]$ui.WakeWordCheck.IsChecked
    if ($newWake -ne [bool]$script:WakeWord) {
        $script:WakeWord = $newWake
        Save-Config
        Restart-WakeListener
    }

    $k = $ui.KeyBox.Password.Trim()
    if (-not $k) { $k = [string]$script:ApiKey }
    if (-not $k) {
        if ($autoOk) {
            $ui.SettingsMsg.Text = 'Settings saved. (No API key yet - AI chat needs one from openrouter.ai/keys.)'
        } else {
            $ui.SettingsMsg.Text = 'Could not write the autostart registry value.'
        }
        return
    }
    $m = $ui.ModelBox2.Text.Trim()
    if (-not $m) { $m = $script:Model }
    $ui.SettingsMsg.Text = 'Verifying key with OpenRouter...'
    $ui.Inbox.Enqueue(@{ kind='savekey'; key=$k; model=$m })
})

# Poll worker results on the UI thread
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:Timer.Add_Tick({
    if ($ui.SpeakRequested) {
        $t = [string]$ui.SpeakRequested
        $ui.SpeakRequested = $null
        Speak $t
    }
    if ($ui.FetchedModels -and -not $ui.ModelsLoaded) {
        $ui.ModelsLoaded = $true
        $ui.Populating = $true
        try {
            $sel1 = $ui.ModelBox.Text; $sel2 = $ui.ModelBox2.Text
            $ui.ModelBox.Items.Clear(); $ui.ModelBox2.Items.Clear()
            foreach ($m in $ui.FetchedModels) {
                [void]$ui.ModelBox.Items.Add($m)
                [void]$ui.ModelBox2.Items.Add($m)
            }
            $ui.ModelBox.Text = $sel1; $ui.ModelBox2.Text = $sel2
        } finally { $ui.Populating = $false }
    }
    if ($ui.SaveResult) {
        $res = $ui.SaveResult
        $ui.SaveResult = $null
        if ($res.ok) {
            $script:ApiKey = $res.key
            $script:Model  = $res.model
            $ui.ApiKey     = $res.key
            $ui.Model      = $res.model
            Save-Config
            $ui.SettingsPanel.Visibility = 'Collapsed'
            $ui.KeyBox.Clear()
            Set-Status 'ONLINE' '#FF40E0D0'
            Add-Message 'JARVIS' ("Key saved (account: " + $res.label + "). Model: " + $res.model + ".")
        } else {
            $ui.SettingsMsg.Text = 'Could not verify key: ' + $res.error
            $ui.SettingsMsg.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFF7B72'))
        }
    }
})
$script:Timer.Start()

$window.Add_StateChanged({
    if (-not $AutoDemo -and $window.WindowState -eq 'Minimized') { Hide-To-Tray }
})

$window.Add_ContentRendered({
    [void]$ui.InputBox.Focus()
    $script:ScanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ScanTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:ScanTimer.Add_Tick({
        try { $script:ScanTimer.Stop() } catch { }
        try {
            $n = Scan-InstalledApps
            if ($n -gt 0 -and -not $AutoDemo) {
                Add-Message 'JARVIS' ("I scanned your Start Menu - $n apps ready to launch. 'open <name>' works for any of them; 'list apps' to browse.")
            }
        } catch { }
        if (-not $AutoDemo -and (Test-VoiceEngine)) { Start-WakeListener }
    })
    $script:ScanTimer.Start()
    if ($AutoDemo) {
        # Self-driving end-to-end test: run real inputs through Submit,
        # dump the transcript to %TEMP%\jarvis_demo.log, then close.
        $script:MuteTTS   = $true
        $script:DemoSteps = @('battery', 'rescan apps', 'list apps note', 'what time is it')
        $script:DemoIdx   = 0
        $script:DemoTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:DemoTimer.Interval = [TimeSpan]::FromSeconds(1.5)
        $script:DemoTimer.Add_Tick({
            if ($script:DemoIdx -lt $script:DemoSteps.Count) {
                $ui.InputBox.Text = $script:DemoSteps[$script:DemoIdx]
                $script:DemoIdx++
                Submit
            } else {
                $script:DemoTimer.Stop()
                try {
                    $lines = foreach ($child in $ui.Log.Children) {
                        $t = ''
                        foreach ($inline in $child.Inlines) { $t += [string]$inline.Text }
                        $t
                    }
                    $lines | Set-Content -Path (Join-Path $env:TEMP 'jarvis_demo.log') -Encoding UTF8
                } catch {
                    $_.Exception.Message | Set-Content -Path (Join-Path $env:TEMP 'jarvis_demo.log') -Encoding UTF8
                }
                $window.Close()
            }
        })
        $script:DemoTimer.Start()
    }
})
# Closing the window hides to tray instead of exiting; Exit tray menu really quits
$window.Add_Closing({
    param($s, $e)
    if ($AutoDemo -or $script:Quitting) { return }
    $e.Cancel = $true
    Hide-To-Tray
})

$window.Add_Closed({
    $ui.Kill = $true
    try { $script:Timer.Stop() } catch { }
    try { $script:PSWorker.Stop() } catch { }
    try { $script:RunspaceWorker.Close() } catch { }
    Stop-WakeListener
    Stop-Speaking
    try { if ($script:TTS) { $script:TTS.Dispose() } } catch { }
    try { if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } } catch { }
    try { $window.Dispatcher.InvokeShutdown() } catch { }
})

# ============================================================
#  Tray icon (summon / wake-word toggle / autostart / exit)
# ============================================================
if (-not $AutoDemo) {
    Add-Type -AssemblyName System.Windows.Forms
    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:TrayIcon.Text = 'JARVIS'
    $script:TrayIcon.Visible = $true
    try {
        $iconStream = [System.Windows.Application]::GetResourceStream((New-Object System.Uri('pack://application:,,,/PresentationFramework.Aero2;component/images/window.ico'))).Stream
        $script:TrayIcon.Icon = New-Object System.Drawing.Icon($iconStream)
    } catch {
        try { $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application } catch { }
    }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $mOpen  = $menu.Items.Add('Open JARVIS');  $mOpen.Add_Click({ Show-Jarvis })
    $mWake  = $menu.Items.Add('Wake word: ' + $(if ($script:WakeWord) { 'ON' } else { 'OFF' }))
    $mWake.Add_Click({
        $script:WakeWord = -not $script:WakeWord
        Save-Config
        Restart-WakeListener
    })
    $mAuto  = $menu.Items.Add('Start with Windows')
    $mAuto.Add_Click({
        Set-AutoStart (-not (Get-AutoStart)) | Out-Null
    })
    [void]$menu.Items.Add('-')
    $mExit  = $menu.Items.Add('Exit'); $mExit.Add_Click({
        $script:Quitting = $true
        try { $script:TrayIcon.Visible = $false } catch { }
        $window.Close()
    })
    $script:TrayIcon.ContextMenuStrip = $menu
    $script:TrayIcon.Add_DoubleClick({ Show-Jarvis })
    $script:TrayIcon.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Jarvis }
    })
    # keep tray labels fresh whenever the settings panel opens
    $ui.KeyBtn.Add_Click({
        $mWake.Text = 'Wake word: ' + $(if ($script:WakeWord) { 'ON' } else { 'OFF' })
        $mAuto.Checked = Get-AutoStart
    })
}

# Initial state
if ($script:ApiKey) { Set-Status 'ONLINE' '#FF40E0D0' }
else {
    Set-Status 'NO KEY' '#FFF0B429'
    Add-Message 'JARVIS' "Hello, sir. I need an OpenRouter API key before we can talk - click 'API Key' in the top bar (get one free at openrouter.ai/keys). Meanwhile, my local commands work: try 'help'."
}

if (-not $AutoDemo) {
    Add-Message 'JARVIS' "Online and listening, sir. Say 'hey Jarvis' any time - even when I'm minimized to the tray."
    Speak "I'm online, sir."
}

if ($VoiceTest) {
    $ok = Test-VoiceEngine
    $ttsOk = $false
    try {
        Add-Type -AssemblyName System.Speech
        $t = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $ttsOk = ($t.GetInstalledVoices().Count -gt 0)
        $male = @($t.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Gender -eq [System.Speech.Synthesis.VoiceGender]::Male } | Select-Object -First 1)
        Write-Output ("TTS voices installed: " + $t.GetInstalledVoices().Count + " | male voice: " + $(if ($male) { $male.VoiceInfo.Name } else { 'NONE' }))
        $t.Dispose()
    } catch { Write-Output ('TTS FAIL: ' + $_.Exception.Message) }
    Write-Output ("STT engine available: $ok")
    if ($ok) {
        Write-Output 'You have 6 seconds to say something (e.g. "what time is it")...'
        $r = Start-Dictation
        if ($r.text) { Write-Output ("HEARD: " + $r.text) }
        elseif ($r.error) { Write-Output ("STT ERROR: " + $r.error) }
        else { Write-Output 'HEARD: (silence)' }
    }
    exit 0
}

if ($Tray) {
    $window.WindowState   = 'Minimized'
    $window.ShowInTaskbar = $false
    $window.Show()
    $window.Hide()
} else {
    $window.Show()
}

[void][System.Windows.Threading.Dispatcher]::Run()
