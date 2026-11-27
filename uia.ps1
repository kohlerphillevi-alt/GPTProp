param([string]$Action, [string]$ArgsB64 = '')
# GPTProp – App-Steuerung über Windows UI Automation. Ausgabe immer als eine JSON-Zeile.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
if (-not ('GpW32' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class GpW32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
}
[void][GpW32]::SetProcessDPIAware()

$A = @{}
if ($ArgsB64) { $A = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgsB64)) | ConvertFrom-Json }
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$TC = [System.Windows.Automation.Condition]::TrueCondition

function Out-Json($o) { $o | ConvertTo-Json -Compress -Depth 6; exit 0 }
function Fail($msg) { Out-Json @{ error = $msg } }

function Get-Windows {
  $res = @()
  foreach ($w in $AE::RootElement.FindAll($TS::Children, $TC)) {
    try {
      $c = $w.Current
      if (-not $c.Name -or $c.IsOffscreen -and -not [GpW32]::IsIconic([IntPtr]$c.NativeWindowHandle)) { continue }
      $pn = ''
      try { $pn = (Get-Process -Id $c.ProcessId -ErrorAction Stop).ProcessName } catch {}
      $res += [pscustomobject]@{ el = $w; title = $c.Name; process = $pn }
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
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $end)
  @()
}
# Minimierte Fenster wiederherstellen, sonst sind ihre Elemente "unsichtbar"
function Restore-Windows($wins) {
  $did = $false
  foreach ($w in $wins) {
    try { $h = [IntPtr]$w.el.Current.NativeWindowHandle; if ($h -ne [IntPtr]::Zero -and [GpW32]::IsIconic($h)) { [void][GpW32]::ShowWindow($h, 9); $did = $true } } catch {}
  }
  if ($did) { Start-Sleep -Milliseconds 700 }
}
function Find-Window([string]$q, [double]$waitSec) { $h = @(Find-Windows $q $waitSec); if ($h.Count) { $h[0] } else { $null } }
function Focus-Window($el) {
  $h = [IntPtr]$el.Current.NativeWindowHandle
  if ($h -eq [IntPtr]::Zero) { return }
  if ([GpW32]::IsIconic($h)) { [void][GpW32]::ShowWindow($h, 9) }
  [GpW32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
  [void][GpW32]::SetForegroundWindow($h)
  [GpW32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 300
}
function CT($e) { ($e.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '') }
$Clickable = @('Button', 'Hyperlink', 'MenuItem', 'TabItem', 'ListItem', 'CheckBox', 'RadioButton', 'ComboBox', 'SplitButton', 'TreeItem', 'DataItem', 'Image', 'Text', 'Custom', 'Group')
function Find-Elements($root, [string]$name, [string]$type) {
  $nl = $name.ToLower().Trim()
  $out = @()
  foreach ($e in $root.FindAll($TS::Descendants, $TC)) {
    try {
      $c = $e.Current
      if ($c.IsOffscreen) { continue }
      $n = ($c.Name + '').Trim()
      $aid = ($c.AutomationId + '')
      $t = CT $e
      if ($type -and $t -ne $type) { continue }
      $score = 0
      if ($n.ToLower() -eq $nl) { $score = 100 }
      elseif ($n -and $n.ToLower().Contains($nl)) { $score = 60 - [Math]::Min($n.Length, 50) / 5 }
      elseif ($aid -and $aid.ToLower() -eq $nl) { $score = 50 }
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
    Start-Sleep -Milliseconds 600
  } while ((Get-Date) -lt $end)
  $null
}
function Mouse-Click([int]$x, [int]$y, [bool]$right, [bool]$double) {
  [void][GpW32]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 80
  $d = 0x0002; $u = 0x0004
  if ($right) { $d = 0x0008; $u = 0x0010 }
  $n = 1; if ($double) { $n = 2 }
  for ($i = 0; $i -lt $n; $i++) {
    [GpW32]::mouse_event($d, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
    [GpW32]::mouse_event($u, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
  }
}
function Escape-Keys([string]$s) { ($s -replace '([+\^%~(){}\[\]])', '{$1}') -replace "`r?`n", '{ENTER}' }
function Wait-Sec { if ($A.wait_seconds -ne $null) { [double]$A.wait_seconds } else { 8 } }

try {
  switch ($Action) {
    'windows' {
      $list = Get-Windows | Where-Object { $_.process -notin @('TextInputHost') } | ForEach-Object { @{ title = $_.title; process = $_.process } }
      Out-Json @{ windows = @($list) }
    }
    'launch' {
      $q = ([string]$A.name).ToLower().Trim()
      if (-not $q) { Fail 'Kein App-Name angegeben.' }
      $apps = Get-StartApps
      $m = $apps | Where-Object { $_.Name.ToLower() -eq $q } | Select-Object -First 1
      if (-not $m) { $m = $apps | Where-Object { $_.Name.ToLower().StartsWith($q) } | Select-Object -First 1 }
      if (-not $m) { $m = $apps | Where-Object { $_.Name.ToLower().Contains($q) } | Select-Object -First 1 }
      if (-not $m) {
        $words = $q -split '\s+' | Where-Object { $_.Length -ge 2 }
        $m = $apps | Where-Object { $n = $_.Name.ToLower(); @($words | Where-Object { $n.Contains($_) }).Count -eq $words.Count } | Select-Object -First 1
      }
      if (-not $m) {
        $sim = $apps | Where-Object { $_.Name.ToLower().Contains($q.Substring(0, [Math]::Min(4, $q.Length))) } | Select-Object -First 8 -ExpandProperty Name
        Fail ("Keine App namens '" + $A.name + "' im Startmenü. Ähnlich: " + (($sim) -join ', '))
      }
      Start-Process ("shell:AppsFolder\" + $m.AppID)
      Out-Json @{ ok = $true; launched = $m.Name }
    }
    'focus' {
      $w = Find-Window $A.window (Wait-Sec)
      if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window) }
      Focus-Window $w.el
      Out-Json @{ ok = $true; window = $w.title; process = $w.process }
    }
    'snapshot' {
      $w = Find-Window $A.window (Wait-Sec)
      if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window + ". Offene Fenster: " + ((Get-Windows | ForEach-Object { $_.title }) -join ' | ')) }
      $filter = ([string]$A.filter).ToLower()
      $items = @(); $count = 0
      $snapWins = @(Find-Windows $A.window 0)
      Restore-Windows $snapWins
      foreach ($ww in $snapWins) {
      foreach ($e in $ww.el.FindAll($TS::Descendants, $TC)) {
        try {
          $c = $e.Current
          if ($c.IsOffscreen) { continue }
          $t = CT $e
          $n = ($c.Name + '').Trim()
          if ($n.Length -gt 120) { $n = $n.Substring(0, 120) + '…' }
          $isInput = $t -in @('Edit', 'ComboBox', 'Document')
          if (-not $n -and -not $isInput) { continue }
          if ($t -in @('Pane', 'Window', 'TitleBar', 'ScrollBar', 'Thumb') -and -not $isInput) { continue }
          if ($filter -and -not ($n.ToLower().Contains($filter))) { continue }
          $r = $c.BoundingRectangle
          $val = ''
          if ($isInput) { try { $val = ([string]$e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value) } catch {} }
          if ($val.Length -gt 80) { $val = $val.Substring(0, 80) + '…' }
          # Kompakt: "Typ: Name [= Wert] @x,y" – spart Zeit bei der KI
          $line = $t + ': ' + $n
          if ($val) { $line += ' = ' + $val }
          if (-not $n -and -not $r.IsEmpty) { $line += ' @' + [int]($r.X + $r.Width / 2) + ',' + [int]($r.Y + $r.Height / 2) }
          if ($items -contains $line) { continue }
          $items += $line
          $count++
          if ($count -ge 180) { break }
        } catch {}
      }
      if ($count -ge 180) { break }
      }
      Out-Json @{ window = $w.title; process = $w.process; elements = $items; truncated = ($count -ge 180); hint = 'Klicken mit ui_click(window, name). Elemente ohne Namen per ui_click_at(x,y).' }
    }
    'click' {
      $w = Find-Window $A.window (Wait-Sec)
      if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window) }
      $nth = 0; if ($A.index) { $nth = [int]$A.index }
      $hit = Wait-Element ([string]$A.window) ([string]$A.name) ([string]$A.type) (Wait-Sec) $nth
      if (-not $hit) { Fail ("Element '" + $A.name + "' nicht gefunden in '" + $w.title + "'. Tipp: ui_snapshot nutzen.") }
      $w = $hit.win
      $e = $hit.el; $method = ''
      Focus-Window $w.el
      if (-not $A.mouse -and -not $A.right -and -not $A.double) {
        try { $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $method = 'invoke' } catch {}
        if (-not $method) { try { $e.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle(); $method = 'toggle' } catch {} }
        if (-not $method) { try { $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); $method = 'select' } catch {} }
        if (-not $method) { try { $e.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); $method = 'expand' } catch {} }
      }
      if (-not $method) {
        Focus-Window $w.el
        $r = $e.Current.BoundingRectangle
        if ($r.IsEmpty) { Fail 'Element hat keine Position auf dem Bildschirm.' }
        Mouse-Click ([int]($r.X + $r.Width / 2)) ([int]($r.Y + $r.Height / 2)) ([bool]$A.right) ([bool]$A.double)
        $method = 'mouse'
      }
      Start-Sleep -Milliseconds 250
      Out-Json @{ ok = $true; clicked = $hit.name; type = $hit.type; method = $method; window = $w.title }
    }
    'type' {
      $text = [string]$A.text
      $w = $null
      if ($A.window) { $w = Find-Window $A.window (Wait-Sec); if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window) } }
      $target = $null
      if ($w -and $A.field) {
        $hit = Wait-Element ([string]$A.window) ([string]$A.field) '' (Wait-Sec) 0
        if (-not $hit) { Fail ("Feld '" + $A.field + "' nicht gefunden.") }
        $target = $hit.el; $w = $hit.win
      }
      if ($w) { Focus-Window $w.el }
      $method = 'keys'
      if ($target) {
        try { $target.SetFocus() } catch {}
        if (-not $A.append) {
          try { $target.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text); $method = 'value' } catch {}
        }
      }
      if ($method -eq 'keys') {
        if ($text.Length -gt 120) {
          # Lange Texte per Zwischenablage einfügen (vorherigen Inhalt wiederherstellen)
          $old = $null; try { $old = [System.Windows.Forms.Clipboard]::GetText() } catch {}
          [System.Windows.Forms.Clipboard]::SetText($text)
          [System.Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 300
          try { if ($old) { [System.Windows.Forms.Clipboard]::SetText($old) } else { [System.Windows.Forms.Clipboard]::Clear() } } catch {}
          $method = 'paste'
        } else {
          # Zeichen einzeln – manche Apps (z. B. Store-Apps) verschlucken schnelle Eingaben
          foreach ($ch in $text.ToCharArray()) { if ($ch -eq "`r") { continue }; [System.Windows.Forms.SendKeys]::SendWait((Escape-Keys ([string]$ch))); Start-Sleep -Milliseconds 25 }
        }
      }
      if ($A.press_enter) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}') }
      Out-Json @{ ok = $true; typed_chars = $text.Length; method = $method }
    }
    'keys' {
      if ($A.window) { $w = Find-Window $A.window (Wait-Sec); if (-not $w) { Fail ("Kein Fenster gefunden: " + $A.window) }; Focus-Window $w.el }
      [System.Windows.Forms.SendKeys]::SendWait([string]$A.keys)
      Out-Json @{ ok = $true; sent = [string]$A.keys }
    }
    'click_at' {
      if ($A.window) { $w = Find-Window $A.window (Wait-Sec); if ($w) { Focus-Window $w.el } }
      Mouse-Click ([int]$A.x) ([int]$A.y) ([bool]$A.right) ([bool]$A.double)
      Out-Json @{ ok = $true; x = [int]$A.x; y = [int]$A.y }
    }
    default { Fail ("Unbekannte Aktion: " + $Action) }
  }
} catch {
  Fail ($_.Exception.Message)
}
