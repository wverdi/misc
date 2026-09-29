# Uso:
#   Interativo (pergunta cliente e comentario):  .\Rustdesk-WindowsAgentAIOInstall.ps1
#   Com parametros:  .\Rustdesk-WindowsAgentAIOInstall.ps1 -Cliente "Madeira" -Comentario "PC da recepcao"
#   Sem interacao (GPO/RMM):  .\Rustdesk-WindowsAgentAIOInstall.ps1 -Cliente "Madeira" -Comentario "PC da recepcao" -Silencioso
param(
    [string]$Cliente = "",
    [string]$Comentario = "",
    [switch]$Silencioso
)

$ErrorActionPreference= 'silentlycontinue'

# Assign the value random password to the password variable
$rustdesk_pw=(-join ((65..90) + (97..122) | Get-Random -Count 12 | % {[char]$_}))

# Get your config string from your Web portal and Fill Below
$rustdesk_cfg="0nIvZmbp5SYu9WajVHbvNnLrNXZkR3c1J3LvozcwRHdoJiOikGchJCLi0TRsxkRHdkTiV0Mi1UayJTOtV1VklmdFV1TMljRThkbXBFRF92NvRUOGN1KiojI5V2aiwiIvZmbp5SYu9WajVHbvNnLrNXZkR3c1JnI6ISehxWZyJCLi8mZulmLh52bpNWds92cus2clRGdzVnciojI0N3boJye"

# ============================ REGISTRO NO GOOGLE SHEETS ============================
# URL do App da Web do Apps Script (termina em /exec)
$sheets_url   = "https://script.google.com/macros/s/AKfycbx3wsiLNjHZqJcno2YrvjHlm__CkYO9dHPPb_n7oVGCiF-yLoAxayNd_EdAWKeIrr7z/exec"
# Mesmo valor da constante TOKEN no Apps Script
$sheets_token = "6Zsn04PpfuCi8BqFkY2DdINJMoy5xgK1"

# Copia local de backup (fica restrita a Administradores/SYSTEM). $false para desativar.
$salvar_local = $true
$log_local    = "$env:ProgramData\RustDesk-Deploy\rustdesk-info.csv"
# ===================================================================================

################################### Please Do Not Edit Below This Line #########################################

# Run as administrator (repassa os parametros para a janela elevada)
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Cliente)    { $argList += " -Cliente `"$($Cliente -replace '"','')`"" }
        if ($Comentario) { $argList += " -Comentario `"$($Comentario -replace '"','')`"" }
        if ($Silencioso) { $argList += " -Silencioso" }
        Start-Process PowerShell -Verb RunAs -ArgumentList $argList
        Exit
    }
}

# Forca TLS 1.2 (Windows antigos falham no GitHub/Google sem isso)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$interativo = -not $Silencioso
$rdPath = "$env:ProgramFiles\RustDesk"

if ($interativo) {
    if ([string]::IsNullOrWhiteSpace($Cliente))    { $Cliente    = Read-Host "Cliente (Enter para deixar em branco)" }
    if ([string]::IsNullOrWhiteSpace($Comentario)) { $Comentario = Read-Host "Comentario, ex: PC do William (Enter para deixar em branco)" }
}

function Get-RustDeskId {
    # O --get-id as vezes volta vazio logo apos configurar; tenta algumas vezes.
    for ($i = 1; $i -le 10; $i++) {
        $id = (& "$rdPath\rustdesk.exe" --get-id | Out-String).Trim()
        if ($id -match '^\d+$') { return $id }
        Start-Sleep -Seconds 3
    }
    return $id
}

function Get-UsuarioLogado {
    # Usuario da sessao ativa (nao a conta usada para elevar o script)
    $u = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($u) { return ($u -split '\\')[-1] }
    return $env:USERNAME
}

function Protect-Folder($path) {
    # Remove heranca e deixa acesso so para Administradores e SYSTEM (senha em texto puro)
    icacls $path /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" | Out-Null
}

function Send-ToSheets($registro) {
    if ([string]::IsNullOrWhiteSpace($sheets_url) -or $sheets_url -like "COLE_AQUI*") {
        echo "URL da planilha nao configurada; registro nao enviado."
        return
    }
    $body = @{
        token       = $sheets_token
        cliente     = $registro.Cliente
        comentario  = $registro.Comentario
        hostname    = $registro.Hostname
        usuario     = $registro.Usuario
        rustdesk_id = $registro.RustDeskID
        senha       = $registro.Senha
        versao      = $registro.Versao
    } | ConvertTo-Json
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)

    $ultimoErro = ""
    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-RestMethod -Uri $sheets_url -Method Post -Body $bytes `
                 -ContentType "application/json; charset=utf-8" -ErrorAction Stop
            if ($r -is [string]) {
                echo "Resposta inesperada da planilha. Confira se o App da Web esta com acesso 'Qualquer pessoa'."
                return
            }
            if ($r.ok) { echo "Registro $($r.acao) na planilha (linha $($r.linha))."; return }
            echo "A planilha recusou o registro: $($r.erro)"
            return
        } catch {
            $ultimoErro = $_.Exception.Message
            Start-Sleep -Seconds 3
        }
    }
    echo "Falha ao enviar para a planilha apos 3 tentativas: $ultimoErro"
}

function Save-RustDeskInfo($id, $pw) {
    $registro = [PSCustomObject]@{
        DataHora   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Cliente    = $Cliente
        Comentario = $Comentario
        Hostname   = $env:COMPUTERNAME
        Usuario    = (Get-UsuarioLogado)
        RustDeskID = $id
        Senha      = $pw
        Versao     = ((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk\").Version)
    }

    if ($salvar_local) {
        try {
            $dir = Split-Path $log_local
            if (!(Test-Path $dir)) {
                New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
                Protect-Folder $dir
            }
            $registro | Export-Csv -Path $log_local -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';' -ErrorAction Stop
            echo "Backup local salvo em: $log_local"
        } catch { echo "Falha ao gravar backup local: $($_.Exception.Message)" }
    }

    Send-ToSheets $registro
}

function Set-RustDeskConfig {
    cd $rdPath
    echo "Inputting configuration now."
    .\rustdesk.exe --config $rustdesk_cfg | Out-Null
    .\rustdesk.exe --password $rustdesk_pw | Out-Null
    $rustdesk_id = Get-RustDeskId

    Save-RustDeskInfo $rustdesk_id $rustdesk_pw

    echo "All done! Please double check the Network settings tab in RustDesk."
    echo ""
    echo "..............................................."
    echo "RustDesk ID: $rustdesk_id"
    echo "Password: $rustdesk_pw"
    echo "..............................................."
    echo ""
    if ($interativo) {
        echo "Press Enter to open RustDesk."
        pause
        .\rustdesk.exe
    }
}

# Checks for the latest version of RustDesk
$url = 'https://www.github.com//rustdesk/rustdesk/releases/latest'
$request = [System.Net.WebRequest]::Create($url)
$response = $request.GetResponse()
$realTagUrl = $response.ResponseUri.OriginalString
$RDLATEST = $realTagUrl.split('/')[-1].Trim('v')
echo "RustDesk $RDLATEST is the latest version."

# Checks the version of RustDesk installed.
$rdver = ((Get-ItemProperty  "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk\").Version)

# Skips to inputting the configuration if the latest version of RustDesk is already installed.
if($rdver -eq "$RDLATEST") {
    echo "RustDesk $rdver is already installed."
    Set-RustDeskConfig
    exit
}

if (!(Test-Path C:\Temp)) {
  New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
}

cd C:\Temp
echo "Downloading RustDesk version $RDLATEST."
Invoke-WebRequest "https://github.com/rustdesk/rustdesk/releases/download/$RDLATEST/rustdesk-$RDLATEST-x86_64.exe" -OutFile "rustdesk.exe" -UseBasicParsing
echo "Installing RustDesk version $RDLATEST."
Start-Process .\rustdesk.exe --silent-install
Start-Sleep -Seconds 10

$ServiceName = 'rustdesk'
$arrService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($arrService -eq $null)
{
    echo "Installing service."
    cd $rdPath
    Start-Process .\rustdesk.exe --install-service -wait -Verbose
    Start-Sleep -Seconds 20
    $arrService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}

while ($arrService.Status -ne 'Running')
{
    Start-Service $ServiceName
    Start-Sleep -seconds 5
    $arrService.Refresh()
}

# Waits for installation to complete before proceeding.
echo "Please wait a few seconds."
Start-Sleep -Seconds 10

Set-RustDeskConfig
