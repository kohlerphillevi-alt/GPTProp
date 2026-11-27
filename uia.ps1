param([string]$Action = '', [string]$ArgsB64 = '', [switch]$Server)
# GPTProp – App-Steuerung über Windows UI Automation.
# Arbeitet im HINTERGRUND: Mauszeiger, Tastatur und aktives Fenster des Nutzers bleiben unberührt.
# Nur wenn "allow_takeover" gesetzt ist, werden Maus/Tastatur kurz benutzt – und nur, wenn der Nutzer gerade nichts tut.
# -Server: bleibt laufen, liest "id|aktion|base64" von der Eingabe und antwortet mit "GP:{json}".
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
if (-not ('GpW32' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class GpW32 {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUT { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr ChildWindowFromPointEx(IntPtr parent, POINT p, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUT l);
  public static uint IdleMs() { var l = new LASTINPUT(); l.cbSize = 8; GetLastInputInfo(ref l); return unchecked((uint)Environment.TickCount - l.dwTime); }
  // Tiefstes Unterfenster an einem Bildschirmpunkt (auch wenn das Fenster verdeckt ist)
  public static IntPtr Deepest(IntPtr top, int x, int y) {
    IntPtr cur = top;
    for (int i = 0; i < 12; i++) {
      var p = new POINT(); p.X = x; p.Y = y; ScreenToClient(cur, ref p);
      IntPtr c = ChildWindowFromPointEx(cur, p, 0x0001 | 0x0004);
      if (c == IntPtr.Zero || c == cur) break;
      cur = c;
    }
    return cur;
  }
}
'@
}
[void][GpW32]::SetProcessDPIAware()

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$TC = [System.Windows.Automation.Condition]::TrueCondition
$VP = [System.Windows.Automation.ValuePattern]::Pattern
# Eigenschaften in einem Rutsch laden – viel schneller als einzeln
$Cache = New-Object System.Windows.Automation.CacheRequest
foreach ($p in @($AE::NameProperty, $AE::AutomationIdProperty, $AE::ControlTypeProperty, $AE::IsOffscreenProperty, $AE::BoundingRectangleProperty, $AE::ClassNameProperty)) { $Cache.Add($p) }
$script:ProcNames = @{}
$script:StartApps = $null
$script:A = $null

function Out-Json($o) { $script:Result = $o; throw 'GPDONE' }
function Fail($msg) { Out-Json @{ error = $msg } }
function Find-All($root) {
  $scope = $Cache.Activate()
  try { $root.FindAll($TS::Descendants, $TC) } finally { $scope.Dispose() }
}

function Get-Windows {
  $res = @()
  foreach ($w in $AE::RootElement.FindAll($TS::Children, $TC)) {
    try {
      $c = $w.Current
      if (-not $c.Name -or $c.IsOffscreen -and -not [GpW32]::IsIconic([IntPtr]$c.NativeWindowHandle)) { continue }
      $procId = $c.ProcessId
      if (-not $script:ProcNames.ContainsKey($procId)) { try { $script:ProcNames[$procId] = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $script:ProcNames[$procId] = '' } }
      $res += [pscustomobject]@{ el = $w; title = $c.Name; process = $script:ProcNames[$procId] }
    } catch {}
  }
  $res
}
# Alle passenden Fenster (eine App kann mehrere Fenster mit gleichem Titel haben)
function Find-Windows([string]$q, [double]$waitSec) {
  if (-not $q) { return @() }
  $ql = $q.ToLower()
  $end = (Get-Date).AddSeconds([Math]::Max($waitSec, 0))
  do {
    $ws = Get-Windows
    $hits = @($ws | Where-Object { $_.title.ToLower() -eq $ql })
    if (-not $hits) { $hits = @($ws | Where-Object { $_.title.ToLower().Contains($ql) }) }
    if (-not $hits) { $hits = @($ws | Where-Object { $_.process -and $_.process.ToLower().Contains($ql.Replace(' ', '')) }) }
    if (-not $hits) {
      # Wörter einzeln (z. B. "NoRisk Launcher" -> Prozess "noriskclient-launcher-v3")
      $words = $ql -split '\s+' | Where-Object { $_.Length -ge 3 }
      if ($words) { $hits = @($ws | Where-Object { $t = ($_.title + ' ' + $_.process).ToLower(); @($words | Where-Object { $t.Contains($_) }).Count -eq $words.Count }) }
    }
    if ($hits) { return $hits }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $end)
  @()
}
# Minimierte Fenster wiederherstellen OHNE sie nach vorn zu holen
function Restore-Windows($wins) {
  $did = $false
  foreach ($w in $wins) {
    try { $h = [IntPtr]$w.el.Current.NativeWindowHandle; if ($h -ne [IntPtr]::Zero -and [GpW32]::IsIconic($h)) { [void][GpW32]::ShowWindow($h, 4); $did = $true } } catch {}
  }
  if ($did) { Start-Sleep -Milliseconds 500 }
}
function Find-Window([string]$q, [double]$waitSec) { $h = @(Find-Windows $q $waitSec); if ($h.Count) { $h[0] } else { $null } }
function CT($e) { ($e.Cached.ControlType.ProgrammaticName -replace '^ControlType\.', '') }
# Eingabefeld? (auch klassische Windows-Felder, die nur als "Pane" erscheinen)
function Test-Input($e) { (CT $e) -in @('Edit', 'Document') -or ($e.Cached.ClassName + '') -match '(?i)(^|\.)(edit|richedit[0-9a-z]*)(\.|$)' }
# Das passende Eingabefeld eines Fensters: das fokussierte, sonst das einzige
function Find-Input($w) {
  $edits = @(Find-All $w.el | Where-Object { -not $_.Cached.IsOffscreen -and (Test-Input $_) })
  $t = $edits | Where-Object { try { $_.Current.HasKeyboardFocus } catch { $false } } | Select-Object -First 1
  if (-not $t -and $edits.Count -eq 1) { $t = $edits[0] }
  $t
}
function Find-Elements($root, [string]$name, [string]$type) {
  $nl = $name.ToLower().Trim()
  $out = @()
  foreach ($e in (Find-All $root)) {
    try {
      $c = $e.Cached
      if ($c.IsOffscreen) { continue }
      $n = ($c.Name + '').Trim()
      $t = CT $e
      if ($type -and $t -ne $type) { continue }
      $score = 0
      if ($n.ToLower() -eq $nl) { $score = 100 }
      elseif ($n -and $n.ToLower().Contains($nl)) { $score = 60 - [Math]::Min($n.Length, 50) / 5 }
      elseif (($c.AutomationId + '').ToLower() -eq $nl) { $score = 50 }
      else { continue }
      if ($t -in @('Button', 'Hyperlink', 'MenuItem', 'TabItem', 'ListItem', 'CheckBox', 'RadioButton', 'SplitButton')) { $score += 20 }
      $out += [pscustomobject]@{ el = $e; score = $score; name = $n; type = $t }
    } catch {}
  }
  $out | Sort-Object score -Descending
}
# Sucht ein Element in allen passenden Fenstern und wartet, bis es erscheint
function Wait-Element([string]$winQuery, [string]$name, [string]$type, [double]$waitSec, [int]$nth) {
  $end = (Get-Date).AddSeconds([Math]::Max($waitSec, 0))
  do {
    $all = @()
    $wins = @(Find-Windows $winQuery 0)
    Restore-Windows $wins
    foreach ($w in $wins) {
      foreach ($c in @(Find-Elements $w.el $name $type)) { $c | Add-Member -NotePropertyName win -NotePropertyValue $w -Force; $all += $c }
    }
    $all = @($all | Sort-Object score -Descending)
    if ($all.Count -gt $nth) { return $all[$nth] }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $end)
  $null
}
function Wait-Sec { if ($script:A.wait_seconds -ne $null) { [double]$script:A.wait_seconds } else { 6 } }
$TakeoverHint = 'Das geht in dieser App nicht im Hintergrund. In GPTProp unter Einstellungen "Maus & Tastatur kurz mitbenutzen" einschalten, falls gewünscht.'

# ---------- Hintergrund-Eingaben (Fensternachrichten) ----------
function Get-LParam([int]$x, [int]$y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }
function Post-Click([IntPtr]$top, [int]$x, [int]$y, [bool]$right, [bool]$double) {
  $h = [GpW32]::Deepest($top, $x, $y)
  $p = New-Object GpW32+POINT; $p.X = $x; $p.Y = $y
  [void][GpW32]::ScreenToClient($h, [ref]$p)
  $l = Get-LParam $p.X $p.Y
  $down = 0x0201; $up = 0x0202; $mk = 1
  if ($right) { $down = 0x0204; $up = 0x0205; $mk = 2 }
  [void][GpW32]::PostMessage($h, 0x0200, [IntPtr]0, $l)
  [void][GpW32]::PostMessage($h, $down, [IntPtr]$mk, $l); Start-Sleep -Milliseconds 30
  [void][GpW32]::PostMessage($h, $up, [IntPtr]0, $l)
  if ($double) { Start-Sleep -Milliseconds 40; [void][GpW32]::PostMessage($h, 0x0203, [IntPtr]$mk, $l); [void][GpW32]::PostMessage($h, $up, [IntPtr]0, $l) }
}
# Fenster, das Tastatureingaben bekommt (Browser/Electron-Apps: Render-Fenster)
function Input-Handle([IntPtr]$top) {
  $r = $AE::FromHandle($top).Current.BoundingRectangle
  if ($r.IsEmpty) { return $top }
  [GpW32]::Deepest($top, [int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
}
function Post-Text([IntPtr]$h, [string]$text) {
  foreach ($ch in $text.ToCharArray()) { if ($ch -eq "`r") { continue }; $code = [int]$ch; if ($code -eq 10) { $code = 13 }; [void][GpW32]::PostMessage($h, 0x0102, [IntPtr]$code, [IntPtr]1); Start-Sleep -Milliseconds 3 }
}
$VKeys = @{ ENTER = 13; TAB = 9; ESC = 27; BACKSPACE = 8; BS = 8; DELETE = 46; DEL = 46; UP = 38; DOWN = 40; LEFT = 37; RIGHT = 39; HOME = 36; END = 35; PGUP = 33; PGDN = 34; F1 = 112; F2 = 113; F3 = 114; F4 = 115; F5 = 116; F6 = 117; F7 = 118; F8 = 119; F9 = 120; F10 = 121; F11 = 122; F12 = 123 }
function Post-Key([IntPtr]$h, [int]$vk) {
  [void][GpW32]::PostMessage($h, 0x0100, [IntPtr]$vk, [IntPtr]1)
  if ($vk -in 13, 9, 8, 27) { [void][GpW32]::PostMessage($h, 0x0102, [IntPtr]$vk, [IntPtr]1) }
  Start-Sleep -Milliseconds 20
  [void][GpW32]::PostMessage($h, 0x0101, [IntPtr]$vk, [IntPtr]0xC0000001)
}

# ---------- Übernahme von Maus/Tastatur (nur wenn erlaubt und Nutzer untätig) ----------
function Use-Takeover([IntPtr]$h, [scriptblock]$do) {
  $end = (Get-Date).AddSeconds(12)
  while ([GpW32]::IdleMs() -lt 1500) {
    if ((Get-Date) -gt $end) { Fail 'Du benutzt gerade Maus oder Tastatur – Aktion ausgelassen, damit nichts durcheinander kommt.' }
    Start-Sleep -Milliseconds 200
  }
  $prev = [GpW32]::GetForegroundWindow()
  $pos = New-Object GpW32+POINT; [void][GpW32]::GetCursorPos([ref]$pos)
  try {
    if ($h -ne [IntPtr]::Zero) {
      [GpW32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [void][GpW32]::SetForegroundWindow($h); [GpW32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 150
    }
    & $do
    Start-Sleep -Milliseconds 120
  } finally {
    [void][GpW32]::SetCursorPos($pos.X, $pos.Y)
    if ($prev -ne [IntPtr]::Zero -and $prev -ne $h) { [void][GpW32]::SetForegroundWindow($prev) }
  }
}
function Mouse-Click([int]$x, [int]$y, [bool]$right, [bool]$double) {
  [void][GpW32]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 40
  $d = 0x0002; $u = 0x0004
  if ($right) { $d = 0x0008; $u = 0x0010 }
  $n = 1; if ($double) { $n = 2 }
  for ($i = 0; $i -lt $n; $i++) { [GpW32]::mouse_event($d, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 25; [GpW32]::mouse_event($u, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 50 }
}
function Escape-Keys([string]$s) { ($s -replace '([+\^%~(){}\[\]])', '{$1}') -replace "`r?`n", '{ENTER}' }
# Element (oder ein direktes Elternelement) ohne Maus auslösen
function Invoke-Element($e) {
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $cur = $e
  for ($i = 0; $i -lt 3 -and $cur; $i++) {
    try { $cur.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return 'invoke' } catch {}
    try { $cur.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle(); return 'toggle' } catch {}
    try { $cur.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); return 'select' } catch {}
    try { $cur.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); return 'expand' } catch {}
    # nur bei reinen Beschriftungen zum Elternelement gehen
    try { if ($cur.Current.ControlType.ProgrammaticName -notmatch 'Text|Image') { break }; $cur = $walker.GetParent($cur) } catch { break }
  }
  ''
}

# ---------- Discord, Browser & Co. (Chromium) ----------
# Diese Apps ignorieren Hintergrund-Eingaben: kurz Fokus holen (Maus bleibt unberührt), tippen, zurückwechseln
function Test-Chromium([IntPtr]$top) {
  try { if ($AE::FromHandle($top).Current.ClassName -like 'Chrome_WidgetWin*') { return $true } } catch {}
  try { if ($AE::FromHandle((Input-Handle $top)).Current.ClassName -like 'Chrome_*') { return $true } } catch {}
  $false
}
function Assert-Front([IntPtr]$h) { if ([GpW32]::GetForegroundWindow() -ne $h) { Fail 'Das Zielfenster ist nicht (mehr) vorne – nichts weiter getippt oder gesendet.' } }
function Use-Keyboard([IntPtr]$h, [scriptblock]$do) {
  $end = (Get-Date).AddSeconds(20)
  while ([GpW32]::IdleMs() -lt 900) {
    if ((Get-Date) -gt $end) { Fail 'Du tippst oder bewegst gerade die Maus – nichts gesendet, damit nichts durcheinander kommt.' }
    Start-Sleep -Milliseconds 100
  }
  $prev = [GpW32]::GetForegroundWindow()
  try {
    if ([GpW32]::IsIconic($h)) { [void][GpW32]::ShowWindow($h, 9) }
    for ($i = 0; $i -lt 3 -and [GpW32]::GetForegroundWindow() -ne $h; $i++) {
      [GpW32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [void][GpW32]::SetForegroundWindow($h); [GpW32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 150
    }
    Assert-Front $h
    & $do
    Start-Sleep -Milliseconds 120
  } finally {
    if ($prev -ne [IntPtr]::Zero -and $prev -ne $h) { [GpW32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [void][GpW32]::SetForegroundWindow($prev); [GpW32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) }
  }
}
function Get-EditText($e) {
  try { return [string]$e.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(8000) } catch {}
  try { return [string]$e.GetCurrentPattern($VP).Current.Value } catch {}
  $null
}
function Norm([string]$s) { ($s -replace '[\s\u200B\uFEFF]', '') }
function Type-Chromium($w, $target, [string]$text) {
  $h = [IntPtr]$w.el.Current.NativeWindowHandle
  if (-not $target) {
    # Nachrichtenfeld (z. B. Discord "Nachricht an @…") bevorzugen
    $edits = @(Find-All $w.el | Where-Object { -not $_.Cached.IsOffscreen -and (CT $_) -eq 'Edit' })
    $target = $edits | Where-Object { $_.Cached.Name -match '^(?i)\s*(nachricht|message)' } | Select-Object -First 1
    if (-not $target) { $target = $edits | Where-Object { try { $_.Current.HasKeyboardFocus } catch { $false } } | Select-Object -First 1 }
    if (-not $target -and $edits.Count -eq 1) { $target = $edits[0] }
    if (-not $target) { Fail 'Kein eindeutiges Eingabefeld gefunden. Bitte field angeben (siehe ui_snapshot).' }
  }
  $script:sent = $false; $script:verified = $false
  Use-Keyboard $h {
    $target.SetFocus(); Start-Sleep -Milliseconds 200
    Assert-Front $h
    $lines = $text.Replace("`r", '')
    $old = $null; try { $old = [System.Windows.Forms.Clipboard]::GetText() } catch {}
    [System.Windows.Forms.Clipboard]::SetText($lines)
    [System.Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 350
    try { if ($old) { [System.Windows.Forms.Clipboard]::SetText($old) } else { [System.Windows.Forms.Clipboard]::Clear() } } catch {}
    $now = Get-EditText $target
    if ($now -ne $null) {
      $probe = Norm $lines; if ($probe.Length -gt 30) { $probe = $probe.Substring(0, 30) }
      $script:verified = (Norm $now).Contains($probe)
      if (-not $script:verified) { Fail 'Der Text ist nicht im Eingabefeld angekommen – nichts gesendet.' }
    }
    if ($script:A.press_enter) {
      Assert-Front $h
      [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Start-Sleep -Milliseconds 350
      $after = Get-EditText $target
      $script:sent = ($after -eq $null) -or -not (Norm $after).Contains((Norm $lines))
    }
  }
  $res = @{ ok = $true; typed_chars = $text.Length; method = 'focus'; verified = $script:verified; window = $w.title; field = $target.Current.Name }
  if ($script:A.press_enter) { $res.sent = $script:sent; if (-not $script:sent) { $res.ok = $false; $res.error = 'Text steht im Feld, wurde aber offenbar nicht abgeschickt.' } }
  Out-Json $res
}

function Invoke-Action([string]$act) {
  $A = $script:A
  switch ($act) {
    'windows' {
      $list = Get-Windows | Where-Object { $_.process -notin @('TextInputHost') } | ForEach-Object { @{ title = $_.title; process = $_.process } }
      Out-Json @{ windows = @($list) }
    }
    'launch' {
      $q = ([string]$A.name).ToLower().Trim()
      if (-not $q) { Fail 'Kein App-Name angegeben.' }
      function Match-App($apps) {
        $m = $apps | Where-Object { $_.Name.ToLower() -eq $q } | Select-Object -First 1
        if (-not $m) { $m = $apps | Where-Object { $_.Name.ToLower().StartsWith($q) } | Select-Object -First 1 }
        if (-not $m) { $m = $apps | Where-Object { $_.Name.ToLower().Contains($q) } | Select-Object -First 1 }
        if (-not $m) {
          $words = $q -split '\s+' | Where-Object { $_.Length -ge 2 }
          $m = $apps | Where-Object { $n = $_.Name.ToLower(); @($words | Where-Object { $n.Contains($_) }).Count -eq $words.Count } | Select-Object -First 1
        }
        $m
      }
      if (-not $script:StartApps) { $script:StartApps = Get-StartApps }
      $m = Match-App $script:StartApps
      if (-not $m) { $script:StartApps = Get-StartApps; $m = Match-App $script:StartApps }
      if (-not $m) {
        $sim = $script:StartApps | Where-Object { $_.Name.ToLower().Contains($q.Substring(0, [Math]::Min(4, $q.Length))) } | Select-Object -First 8 -ExpandProperty Name
        Fail ("Keine App namens '" + $A.name + "' im Startmenü. Ähnlich: " + (($sim) -join ', '))
      }
      Start-Process ("shell:AppsFolder\" + $m.AppID)
      Out-Json @{ ok = $true; launched = $m.Name }
    }
    'snapshot' {
      $w = Find-Window $A.window (Wait-Sec)
      if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window + ". Offene Fenster: " + ((Get-Windows | ForEach-Object { $_.title }) -join ' | ')) }
      $filter = ([string]$A.filter).ToLower()
      $items = New-Object System.Collections.Generic.List[string]; $seen = @{}
      $snapWins = @(Find-Windows $A.window 0)
      Restore-Windows $snapWins
      foreach ($ww in $snapWins) {
        foreach ($e in (Find-All $ww.el)) {
          try {
            $c = $e.Cached
            if ($c.IsOffscreen) { continue }
            $t = CT $e
            $n = ($c.Name + '').Trim()
            if ($n.Length -gt 120) { $n = $n.Substring(0, 120) + '…' }
            $isInput = $t -eq 'ComboBox' -or (Test-Input $e)
            if ($isInput -and $t -eq 'Pane') { $t = 'Edit' }
            if (-not $n -and -not $isInput) { continue }
            if ($t -in @('Window', 'TitleBar', 'ScrollBar', 'Thumb') -and -not $isInput) { continue }
            if ($filter -and -not ($n.ToLower().Contains($filter))) { continue }
            $val = ''
            if ($isInput) { try { $val = ([string]$e.GetCurrentPattern($VP).Current.Value) } catch {} }
            if ($val.Length -gt 80) { $val = $val.Substring(0, 80) + '…' }
            # Kompakt: "Typ: Name [= Wert] @x,y" – spart Zeit bei der KI
            $line = $t + ': ' + $n
            if ($val) { $line += ' = ' + $val }
            $r = $c.BoundingRectangle
            if (-not $n -and -not $r.IsEmpty) { $line += ' @' + [int]($r.X + $r.Width / 2) + ',' + [int]($r.Y + $r.Height / 2) }
            if ($seen.ContainsKey($line)) { continue }
            $seen[$line] = 1; $items.Add($line)
            if ($items.Count -ge 150) { break }
          } catch {}
        }
        if ($items.Count -ge 150) { break }
      }
      Out-Json @{ window = $w.title; process = $w.process; elements = $items.ToArray(); truncated = ($items.Count -ge 150); hint = 'Klicken mit ui_click(window, name). Elemente ohne Namen per ui_click_at(x,y).' }
    }
    'click' {
      $w = Find-Window $A.window (Wait-Sec)
      if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window) }
      $nth = 0; if ($A.index) { $nth = [int]$A.index }
      $hit = Wait-Element ([string]$A.window) ([string]$A.name) ([string]$A.type) (Wait-Sec) $nth
      if (-not $hit) { Fail ("Element '" + $A.name + "' nicht gefunden in '" + $w.title + "'. Tipp: ui_snapshot nutzen.") }
      $w = $hit.win; $e = $hit.el; $method = ''
      $special = [bool]$A.right -or [bool]$A.double
      $force = [bool]$A.mouse -and [bool]$A.allow_takeover
      if (-not $special -and -not $force) { $method = Invoke-Element $e }
      if (-not $method) {
        $r = $e.Current.BoundingRectangle
        if ($r.IsEmpty) { Fail 'Element hat keine Position auf dem Bildschirm.' }
        $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
        $h = [IntPtr]$w.el.Current.NativeWindowHandle
        if ($A.allow_takeover) { Use-Takeover $h { Mouse-Click $x $y ([bool]$A.right) ([bool]$A.double) }; $method = 'mouse' }
        elseif ($A.allow_keys -and -not $special -and (Test-Chromium $h)) {
          # Discord/Browser ignorieren Hintergrund-Klicks: Element anwählen und mit Enter auslösen (ohne Maus)
          Use-Keyboard $h { $e.SetFocus(); Start-Sleep -Milliseconds 200; if (-not $e.Current.HasKeyboardFocus) { Fail ('"' + $hit.name + '" lässt sich hier nur mit der Maus anklicken. ' + $TakeoverHint) }; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Start-Sleep -Milliseconds 250 }
          $method = 'focus'
        }
        else { Post-Click $h $x $y ([bool]$A.right) ([bool]$A.double); $method = 'background' }
      }
      Start-Sleep -Milliseconds 60
      $res = @{ ok = $true; clicked = $hit.name; type = $hit.type; method = $method; window = $w.title }
      if ($method -eq 'background') { $res.hint = 'Im Hintergrund geklickt (nicht bestätigt). Mit ui_snapshot prüfen, ob es gewirkt hat.' }
      Out-Json $res
    }
    'type' {
      $text = [string]$A.text
      if (-not $A.window) {
        if (-not $A.allow_takeover) { Fail 'Bitte das Zielfenster angeben (window). Ohne Fenster kann ich nicht im Hintergrund tippen.' }
        Use-Takeover ([IntPtr]::Zero) { [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys $text)); if ($A.press_enter) { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') } }
        Out-Json @{ ok = $true; typed_chars = $text.Length; method = 'keys' }
      }
      $w = Find-Window $A.window (Wait-Sec)
      if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window) }
      $target = $null
      if ($A.field) {
        $hit = Wait-Element ([string]$A.window) ([string]$A.field) '' (Wait-Sec) 0
        if (-not $hit) { Fail ("Feld '" + $A.field + "' nicht gefunden.") }
        $target = $hit.el; $w = $hit.win
      } else {
        Restore-Windows @($w)
        $target = Find-Input $w
      }
      $h = [IntPtr]$w.el.Current.NativeWindowHandle
      if (($A.allow_keys -or $A.allow_takeover) -and (Test-Chromium $h)) {
        if (-not $A.field) { $target = $null }
        Type-Chromium $w $target $text
      }
      $method = ''
      # 1) Wert direkt setzen (kein Fokus nötig) und nachprüfen
      if ($target) {
        try {
          $vpat = $target.GetCurrentPattern($VP)
          if (-not $vpat.Current.IsReadOnly) {
            $new = $text; if ($A.append) { $new = [string]$vpat.Current.Value + $text }
            $vpat.SetValue($new)
            Start-Sleep -Milliseconds 40
            if (([string]$vpat.Current.Value).Replace("`r", '').Contains($text.Replace("`r", ''))) { $method = 'value' }
          }
        } catch {}
      }
      $nh = [IntPtr]::Zero; if ($target) { try { $nh = [IntPtr]$target.Current.NativeWindowHandle } catch {} }
      if ($nh -eq [IntPtr]::Zero) { $nh = Input-Handle $h }
      # Feld im Hintergrund anwählen, damit Text und Enter dort landen (holt das Fenster nicht nach vorn)
      if ($target -and $nh -ne $h -and -not $A.allow_takeover -and ($method -eq '' -or $A.press_enter)) {
        try { $tr = $target.Current.BoundingRectangle; if (-not $tr.IsEmpty) { Post-Click $h ([int]($tr.Right - 8)) ([int]($tr.Y + $tr.Height / 2)) $false $false; Start-Sleep -Milliseconds 60; if (-not $method) { Post-Key $nh 35 } } } catch {}
      }
      if (-not $method) {
        if ($A.allow_takeover) {
          Use-Takeover $h {
            if ($target) { try { $target.SetFocus() } catch {} }
            if ($text.Length -gt 80) {
              $old = $null; try { $old = [System.Windows.Forms.Clipboard]::GetText() } catch {}
              [System.Windows.Forms.Clipboard]::SetText($text); [System.Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 200
              try { if ($old) { [System.Windows.Forms.Clipboard]::SetText($old) } else { [System.Windows.Forms.Clipboard]::Clear() } } catch {}
            } else { foreach ($ch in $text.ToCharArray()) { if ($ch -eq "`r") { continue }; [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys ([string]$ch))); Start-Sleep -Milliseconds 15 } }
            if ($A.press_enter) { [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
          }
          Out-Json @{ ok = $true; typed_chars = $text.Length; method = 'keys' }
        }
        Post-Text $nh $text; $method = 'background'
      }
      if ($A.press_enter) { Start-Sleep -Milliseconds 60; Post-Key $nh 13 }
      $res = @{ ok = $true; typed_chars = $text.Length; method = $method; window = $w.title }
      if ($method -eq 'background' -or $A.press_enter) { $res.hint = 'Im Hintergrund gesendet (nicht bestätigt). Mit ui_snapshot prüfen; wenn nichts passiert ist: ' + $TakeoverHint }
      Out-Json $res
    }
    'keys' {
      $keys = [string]$A.keys
      $w = $null; $h = [IntPtr]::Zero
      if ($A.window) { $w = Find-Window $A.window (Wait-Sec); if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window) }; $h = [IntPtr]$w.el.Current.NativeWindowHandle }
      if ($w -and ($A.allow_keys -or $A.allow_takeover) -and (Test-Chromium $h)) {
        Restore-Windows @($w)
        Use-Keyboard $h { [System.Windows.Forms.SendKeys]::SendWait($keys); Start-Sleep -Milliseconds 120 }
        Out-Json @{ ok = $true; sent = $keys; method = 'focus' }
      }
      # Einfache Tasten ({ENTER}, {TAB 3} …) und Text gehen im Hintergrund
      $simple = $keys -match '^(\{[A-Za-z0-9]+( \d+)?\}|[^+^%~(){}\[\]])+$'
      if ($w -and $simple) {
        Restore-Windows @($w)
        $ih = [IntPtr]::Zero
        $inp = Find-Input $w
        if ($inp) { try { $ih = [IntPtr]$inp.Current.NativeWindowHandle } catch {} }
        if ($ih -eq [IntPtr]::Zero) { $ih = Input-Handle $h }
        $ok = $true
        foreach ($m in [regex]::Matches($keys, '\{([A-Za-z0-9]+)(?: (\d+))?\}|(.)')) {
          if ($m.Groups[1].Success) {
            $k = $m.Groups[1].Value.ToUpper(); if (-not $VKeys.ContainsKey($k)) { $ok = $false; break }
            $n = 1; if ($m.Groups[2].Success) { $n = [Math]::Min([int]$m.Groups[2].Value, 50) }
            for ($i = 0; $i -lt $n; $i++) { Post-Key $ih $VKeys[$k] }
          } else { Post-Text $ih $m.Groups[3].Value }
        }
        if ($ok -and -not $A.allow_takeover) { Out-Json @{ ok = $true; sent = $keys; method = 'background'; hint = 'Nicht bestätigt – mit ui_snapshot prüfen.' } }
        if ($ok) { Out-Json @{ ok = $true; sent = $keys; method = 'background' } }
      }
      if (-not $A.allow_takeover) { Fail ('Tastenkombinationen wie "' + $keys + '" brauchen die Tastatur. ' + $TakeoverHint) }
      Use-Takeover $h { [System.Windows.Forms.SendKeys]::SendWait($keys) }
      Out-Json @{ ok = $true; sent = $keys; method = 'keys' }
    }
    'click_at' {
      $x = [int]$A.x; $y = [int]$A.y
      $h = [IntPtr]::Zero
      if ($A.window) { $w = Find-Window $A.window (Wait-Sec); if ($w) { Restore-Windows @($w); $h = [IntPtr]$w.el.Current.NativeWindowHandle } }
      if ($A.allow_takeover) { Use-Takeover $h { Mouse-Click $x $y ([bool]$A.right) ([bool]$A.double) }; Out-Json @{ ok = $true; x = $x; y = $y; method = 'mouse' } }
      if ($h -eq [IntPtr]::Zero) { $p = New-Object GpW32+POINT; $p.X = $x; $p.Y = $y; $h = [GpW32]::WindowFromPoint($p) }
      if ($h -eq [IntPtr]::Zero) { Fail 'An dieser Stelle ist kein Fenster.' }
      Post-Click $h $x $y ([bool]$A.right) ([bool]$A.double)
      Out-Json @{ ok = $true; x = $x; y = $y; method = 'background'; hint = 'Nicht bestätigt – mit ui_snapshot prüfen.' }
    }
    default { Fail ("Unbekannte Aktion: " + $act) }
  }
}

function Run-Request([string]$act, [string]$b64) {
  $script:Result = $null
  try {
    $script:A = [pscustomobject]@{}
    if ($b64) { $script:A = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json }
    Invoke-Action $act
  } catch {
    if ($_.Exception.Message -ne 'GPDONE') { $script:Result = @{ error = $_.Exception.Message } }
  }
  $script:Result
}

if ($Server) {
  [Console]::Out.WriteLine('GPREADY'); [Console]::Out.Flush()
  while ($true) {
    $line = [Console]::In.ReadLine()
    if ($line -eq $null) { break }
    $p = $line.Split('|')
    if ($p.Count -lt 3) { continue }
    $res = Run-Request $p[1] $p[2]
    if ($res -eq $null) { $res = @{ error = 'Keine Antwort.' } }
    $res['id'] = $p[0]
    [Console]::Out.WriteLine('GP:' + ($res | ConvertTo-Json -Compress -Depth 6)); [Console]::Out.Flush()
  }
} else {
  Run-Request $Action $ArgsB64 | ConvertTo-Json -Compress -Depth 6
}
