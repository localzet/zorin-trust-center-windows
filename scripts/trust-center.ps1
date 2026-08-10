param([switch]$Tray)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$StateDir = Join-Path $env:APPDATA 'ZorinTrust'
$LocalDir = Join-Path $env:LOCALAPPDATA 'ZorinTrust'
$Agent = Join-Path $LocalDir 'bin\zorin-host-agent.exe'
$UiDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $UiDir
if (Test-Path (Join-Path $RootDir '2-PAIR-OWNER.bat')) { $BundleRoot = $RootDir } else { $BundleRoot = $null }

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Raw -Path $Path | ConvertFrom-Json) } catch { return $null }
}
function Get-HostInfo {
    $x = Read-JsonFile (Join-Path $StateDir 'host-info.json')
    if ($null -ne $x) { return $x }
    return [pscustomobject]@{ version='?'; host_fingerprint='?'; identity_provider='unknown'; protocol='ZTRUST/2'; pair_verification='?' }
}
function Get-TrustState {
    $health = Read-JsonFile (Join-Path $StateDir 'daemon-health.json')
    $sessions = Read-JsonFile (Join-Path $StateDir 'session.json')
    $host = Get-HostInfo
    $list = @()
    if ($null -ne $sessions) { if ($sessions -is [System.Array]) { $list=@($sessions) } else { $list=@($sessions) } }
    $trusted = $false; $present = $false; $phone = ''; $since=$null; $lastSeen=$null
    foreach($s in $list) {
        if ($s.trusted) { $trusted=$true; if(-not $phone){$phone=$s.phone_fingerprint}; $since=$s.since; $lastSeen=$s.last_seen }
        if ($s.user_present) { $present=$true }
    }
    $devices=@();$reverse=@();$healthAge=999
    if($null-ne$health){if($health.devices){$devices=@($health.devices)};if($health.reverse_ok){$reverse=@($health.reverse_ok)};try{$healthAge=((Get-Date)-(Get-Date $health.updated)).TotalSeconds}catch{}}
    $transport = ($devices.Count -gt 0 -and $reverse.Count -gt 0 -and $healthAge -lt 8)
    $authority = $trusted -and $present
    $transportText = if($transport){'USB / ADB'}elseif($healthAge -lt 8){'RECOVERING'}else{'OFFLINE'}
    return [pscustomobject]@{Trusted=$trusted;Present=$present;Authority=$authority;Transport=$transport;TransportText=$transportText;Phone=$phone;Since=$since;LastSeen=$lastSeen;Health=$health;Host=$host}
}
function Last-Events([int]$Count=40) {
    $p=Join-Path $StateDir 'events.jsonl'; if(-not(Test-Path $p)){return @()}
    $lines=@(Get-Content $p -Tail $Count);$out=@();foreach($line in $lines){try{$out+=($line|ConvertFrom-Json)}catch{}};return $out
}
function Set-StateText($Control,[string]$Text,[string]$Kind) {
    $Control.Text=$Text
    switch($Kind){'good'{$Control.Foreground='#FFF04B5F'}'warn'{$Control.Foreground='#FFF2B84B'}'bad'{$Control.Foreground='#FFFF6478'}default{$Control.Foreground='#FFB7C3CF'}}
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zorin Trust Center" Width="1040" Height="720" MinWidth="900" MinHeight="620"
        Background="#FF080D13" Foreground="#FFE7EDF4" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="Button"><Setter Property="Background" Value="#FF24151B"/><Setter Property="Foreground" Value="#FFF04B5F"/><Setter Property="BorderBrush" Value="#FF6A2935"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
        <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="#FF0E151E"/><Setter Property="BorderBrush" Value="#FF26313D"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="10"/><Setter Property="Padding" Value="14"/></Style>
    </Window.Resources>
    <Grid Margin="22">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="110"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="0,0,0,16">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel><TextBlock Text="ZORIN TRUST" FontSize="30" FontWeight="Bold"/><TextBlock Text="TRUST CENTER  /  OWNER WORKSTATION" Foreground="#FF8292A1" FontSize="12"/></StackPanel>
            <Border Grid.Column="1" Background="#FF25141A" BorderBrush="#FF6A2935" BorderThickness="1" CornerRadius="14" Padding="14,7" VerticalAlignment="Center"><TextBlock x:Name="OverallBadge" Text="OFFLINE" Foreground="#FFF04B5F" FontWeight="Bold"/></Border>
        </Grid>
        <Grid Grid.Row="1" Margin="0,0,0,16">
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}" Margin="0,0,10,0"><StackPanel><TextBlock Text="DEVICE TRUST" Foreground="#FF778A9C"/><TextBlock x:Name="DeviceTrust" Text="OFFLINE" FontSize="21" FontWeight="Bold" Margin="0,12,0,0"/></StackPanel></Border>
            <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,10,0"><StackPanel><TextBlock Text="OWNER PRESENCE" Foreground="#FF778A9C"/><TextBlock x:Name="OwnerPresence" Text="UNKNOWN" FontSize="21" FontWeight="Bold" Margin="0,12,0,0"/></StackPanel></Border>
            <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0,0,10,0"><StackPanel><TextBlock Text="AUTHORITY" Foreground="#FF778A9C"/><TextBlock x:Name="Authority" Text="SUSPENDED" FontSize="21" FontWeight="Bold" Margin="0,12,0,0"/></StackPanel></Border>
            <Border Grid.Column="3" Style="{StaticResource Card}"><StackPanel><TextBlock Text="TRANSPORT" Foreground="#FF778A9C"/><TextBlock x:Name="Transport" Text="OFFLINE" FontSize="21" FontWeight="Bold" Margin="0,12,0,0"/></StackPanel></Border>
        </Grid>
        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="1.05*"/><ColumnDefinition Width="1.35*"/></Grid.ColumnDefinitions>
            <Grid Grid.Column="0" Margin="0,0,14,0">
                <Grid.RowDefinitions><RowDefinition Height="220"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                    <Grid><Canvas x:Name="GraphCanvas">
                        <Ellipse x:Name="HostNode" Width="90" Height="90" Fill="#FF17212B" Stroke="#FF5B6977" StrokeThickness="2" Canvas.Left="55" Canvas.Top="52"/>
                        <TextBlock Text="WINDOWS" FontWeight="Bold" Canvas.Left="69" Canvas.Top="86"/>
                        <Line x:Name="TrustLine" X1="145" Y1="97" X2="310" Y2="97" Stroke="#FF3A4652" StrokeThickness="5"/>
                        <Ellipse x:Name="PhoneNode" Width="90" Height="90" Fill="#FF17212B" Stroke="#FF5B6977" StrokeThickness="2" Canvas.Left="310" Canvas.Top="52"/>
                        <TextBlock Text="PHONE" FontWeight="Bold" Canvas.Left="332" Canvas.Top="86"/>
                        <TextBlock x:Name="GraphCaption" Text="NO TRUST SESSION" Foreground="#FF7F91A2" Canvas.Left="155" Canvas.Top="118"/>
                    </Canvas></Grid>
                </Border>
                <Border Grid.Row="1" Style="{StaticResource Card}"><StackPanel>
                    <TextBlock Text="SECURITY" FontWeight="Bold" FontSize="16"/>
                    <Grid Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                        <TextBlock Text="Host identity" Foreground="#FF8192A2"/><TextBlock x:Name="IdentityProvider" Grid.Column="1" HorizontalAlignment="Right"/>
                        <TextBlock Grid.Row="1" Text="Protocol" Foreground="#FF8192A2" Margin="0,8,0,0"/><TextBlock x:Name="Protocol" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" Margin="0,8,0,0"/>
                        <TextBlock Grid.Row="2" Text="Pair verification" Foreground="#FF8192A2" Margin="0,8,0,0"/><TextBlock x:Name="PairCode" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" Margin="0,8,0,0" FontWeight="Bold" Foreground="#FFF2B84B"/>
                        <TextBlock Grid.Row="3" Text="Phone fingerprint" Foreground="#FF8192A2" Margin="0,8,0,0"/><TextBlock x:Name="PhoneFp" Grid.Row="3" Grid.Column="1" HorizontalAlignment="Right" Margin="0,8,0,0" TextTrimming="CharacterEllipsis" MaxWidth="280"/>
                    </Grid>
                    <StackPanel Orientation="Horizontal" Margin="0,18,0,0"><Button x:Name="TpmButton" Content="MIGRATE TO TPM"/><Button x:Name="ProofButton" Content="REQUEST OWNER PROOF"/></StackPanel>
                </StackPanel></Border>
            </Grid>
            <Border Grid.Column="1" Style="{StaticResource Card}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="EVENT TIMELINE" FontWeight="Bold" FontSize="16"/><ListBox x:Name="Timeline" Grid.Row="1" Margin="0,12,0,0" Background="Transparent" BorderThickness="0" Foreground="#FFD4DDE6" FontFamily="Consolas" FontSize="12"/></Grid></Border>
        </Grid>
        <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,16,0,0"><Button x:Name="PairButton" Content="PAIR PHONE"/><Button x:Name="ConsoleButton" Content="OWNER CONSOLE"/><Button x:Name="DoctorButton" Content="DOCTOR"/><Button x:Name="RefreshButton" Content="REFRESH"/></StackPanel>
    </Grid>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)
$names=@('OverallBadge','DeviceTrust','OwnerPresence','Authority','Transport','TrustLine','HostNode','PhoneNode','GraphCaption','IdentityProvider','Protocol','PairCode','PhoneFp','Timeline','PairButton','ConsoleButton','DoctorButton','RefreshButton','TpmButton','ProofButton')
foreach($n in $names){Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script}

function Update-Ui {
    $s=Get-TrustState
    Set-StateText $DeviceTrust ($(if($s.Trusted){'ACTIVE'}else{'OFFLINE'})) $(if($s.Trusted){'good'}else{'dim'})
    Set-StateText $OwnerPresence ($(if($s.Present){'PRESENT'}else{'LOCKED'})) $(if($s.Present){'good'}else{'warn'})
    Set-StateText $Authority ($(if($s.Authority){'ENABLED'}else{'SUSPENDED'})) $(if($s.Authority){'good'}else{'warn'})
    Set-StateText $Transport $s.TransportText $(if($s.Transport){'good'}elseif($s.TransportText -eq 'RECOVERING'){'warn'}else{'dim'})
    if($s.Trusted){$OverallBadge.Text=if($s.Present){'OWNER LINKED'}else{'DEVICE TRUST'};$OverallBadge.Foreground='#FFF04B5F';$TrustLine.Stroke='#FFF04B5F';$HostNode.Stroke='#FFF04B5F';$PhoneNode.Stroke='#FFF04B5F';$GraphCaption.Text=if($s.Present){'MUTUAL TRUST + OWNER PRESENT'}else{'DEVICE TRUST / OWNER LOCKED'}}else{$OverallBadge.Text=if($s.Transport){'AUTHENTICATING'}else{'OFFLINE'};$OverallBadge.Foreground='#FF93A3B2';$TrustLine.Stroke='#FF3A4652';$HostNode.Stroke='#FF5B6977';$PhoneNode.Stroke='#FF5B6977';$GraphCaption.Text=if($s.Transport){'USB CONNECTED / WAITING FOR TRUST'}else{'NO TRUST SESSION'}}
    $IdentityProvider.Text=[string]$s.Host.identity_provider;$Protocol.Text=[string]$s.Host.protocol;$PairCode.Text=[string]$s.Host.pair_verification;$PhoneFp.Text=if($s.Phone){$s.Phone}else{'—'}
    $Timeline.Items.Clear();$ev=Last-Events 60;[array]::Reverse($ev);foreach($e in $ev){$t='';try{$t=(Get-Date $e.time).ToString('HH:mm:ss')}catch{};$detail=if($e.detail){'  '+$e.detail}else{''};[void]$Timeline.Items.Add(('{0}  {1}{2}' -f $t,$e.title,$detail))}
}
function Start-Terminal([string]$Command) { Start-Process powershell.exe -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-Command',$Command }
$RefreshButton.Add_Click({Update-Ui})
$DoctorButton.Add_Click({if(Test-Path $Agent){Start-Terminal ('& "{0}" doctor' -f $Agent)}})
$ConsoleButton.Add_Click({if(Test-Path $Agent){Start-Terminal ('& "{0}" gate --action owner.console --resource local:owner-console -- powershell.exe' -f $Agent)}})
$ProofButton.Add_Click({if(Test-Path $Agent){Start-Terminal ('& "{0}" authorize --action owner.session --resource local:trust-center' -f $Agent)}})
$TpmButton.Add_Click({if($BundleRoot -and (Test-Path (Join-Path $BundleRoot '9-MIGRATE-HOST-TO-TPM.bat'))){Start-Process (Join-Path $BundleRoot '9-MIGRATE-HOST-TO-TPM.bat')}elseif(Test-Path $Agent){Start-Terminal ('& "{0}" identity migrate-tpm' -f $Agent)}})
$PairButton.Add_Click({if($BundleRoot -and (Test-Path (Join-Path $BundleRoot '2-PAIR-OWNER.bat'))){Start-Process (Join-Path $BundleRoot '2-PAIR-OWNER.bat')}else{[System.Windows.MessageBox]::Show('Open the v0.4 bundle and run 2-PAIR-OWNER.bat for an explicit pairing ceremony.','Zorin Trust')|Out-Null}})

$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(1);$timer.Add_Tick({Update-Ui});$timer.Start();Update-Ui
$notify=$null
if($Tray){
    $notify=New-Object System.Windows.Forms.NotifyIcon;$notify.Icon=[System.Drawing.SystemIcons]::Shield;$notify.Text='Zorin Trust Center';$notify.Visible=$true
    $menu=New-Object System.Windows.Forms.ContextMenuStrip;$open=$menu.Items.Add('Open Trust Center');$exit=$menu.Items.Add('Exit');$open.Add_Click({$Window.Show();$Window.Activate()});$exit.Add_Click({$notify.Visible=$false;$timer.Stop();$Window.Tag='exit';$Window.Close()});$notify.ContextMenuStrip=$menu;$notify.Add_DoubleClick({$Window.Show();$Window.Activate()})
    $Window.Add_Closing({param($sender,$e) if($Window.Tag -ne 'exit'){$e.Cancel=$true;$Window.Hide()}})
}
[void]$Window.ShowDialog();if($notify){$notify.Visible=$false;$notify.Dispose()}
