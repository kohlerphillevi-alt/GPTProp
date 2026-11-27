param([double]$MinConf = 0.33, [string]$WaveFile = '')
# GPTProp – Aktivierungswort "Hey Prop" (offline, Windows-Spracherkennung).
# Ausgabe pro Zeile: READY | WAKE <conf> | WAKECMD <conf> <base64-wav> | ERROR <text>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
function Say([string]$s) { [Console]::Out.WriteLine($s); [Console]::Out.Flush() }
try {
  Add-Type -AssemblyName System.Speech
  $info = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | Where-Object { $_.Culture.Name -eq 'de-DE' } | Select-Object -First 1
  if (-not $info) { $info = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | Select-Object -First 1 }
  if (-not $info) { Say 'ERROR Keine Windows-Spracherkennung installiert.'; exit 1 }
  $rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine($info)

  # "Prop" steht in keinem Wörterbuch -> Aussprache als Lautschrift (IPA) vorgeben
  $doc = New-Object System.Speech.Recognition.SrgsGrammar.SrgsDocument
  $doc.Culture = $info.Culture
  $doc.PhoneticAlphabet = [System.Speech.Recognition.SrgsGrammar.SrgsPhoneticAlphabet]::Ipa
  $rule = New-Object System.Speech.Recognition.SrgsGrammar.SrgsRule('wake')
  $alts = New-Object System.Speech.Recognition.SrgsGrammar.SrgsOneOf
  foreach ($pr in @('heɪprɔp', 'haɪprɔp', 'hɛɪprɔp', 'heɪpʁɔp', 'haɪpʁɔp', 'hɛprɔp', 'heɪprɔːp')) {
    $t = New-Object System.Speech.Recognition.SrgsGrammar.SrgsToken('heyprop'); $t.Pronunciation = $pr
    $alts.Add((New-Object System.Speech.Recognition.SrgsGrammar.SrgsItem($t)))
  }
  $rule.Add($alts)
  # Danach darf beliebiger Befehl folgen ("Hey Prop, öffne Spotify")
  $rule.Add([System.Speech.Recognition.SrgsGrammar.SrgsRuleRef]::Garbage)
  $doc.Rules.Add($rule); $doc.Root = $rule
  $g = New-Object System.Speech.Recognition.Grammar($doc); $g.Name = 'wake'
  $rec.LoadGrammar($g)

  if ($WaveFile) { $rec.SetInputToWaveFile($WaveFile) } else { $rec.SetInputToDefaultAudioDevice() }
  Say 'READY'
  while ($true) {
    $r = $null
    try { $r = $rec.Recognize([TimeSpan]::FromSeconds(30)) } catch { if ($WaveFile) { break } else { throw } }
    if (-not $r) { if ($WaveFile) { break } else { continue } }
    if ($r.Confidence -lt $MinConf) { continue }
    $conf = [Math]::Round($r.Confidence, 2)
    # Audio nach dem Aktivierungswort herausschneiden (der Befehl)
    $tail = $null
    try {
      $w = $r.Words | Where-Object { $_.Text -eq 'heyprop' } | Select-Object -First 1
      if ($w -and $r.Audio) {
        $start = $w.AudioPosition + $w.AudioDuration
        $rest = $r.Audio.Duration - $start
        if ($rest.TotalMilliseconds -gt 700) {
          $ms = New-Object System.IO.MemoryStream
          $r.Audio.GetRange($start, $rest).WriteToWaveStream($ms)
          $tail = [Convert]::ToBase64String($ms.ToArray())
        }
      }
    } catch {}
    if ($tail) { Say ("WAKECMD " + $conf + " " + $tail) } else { Say ("WAKE " + $conf) }
  }
} catch {
  Say ('ERROR ' + $_.Exception.Message)
  exit 1
}
