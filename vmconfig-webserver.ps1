# Install IIS with ASP.Net support
Install-WindowsFeature -name Web-Server, Web-Asp-Net45 -IncludeManagementTools

# Create a default file containing WAN IP, ipconfig output, and a dump of request headers
$HTML = "<pre>" + $ENV:COMPUTERNAME + "<br/>"
$HTML += "WAN IP: $(irm ifconfig.me) <br/><hr/>"
$HTML += "Request headers: <br/>"
$HTML += '<%= Request.Headers.ToString().Replace("&","<br/>") %></pre>'
$HTML > C:\inetpub\wwwroot\default.aspx

# Create subfolders
"about", "blog" | % {
    New-Item -ItemType Directory -Path C:\inetpub\wwwroot\ -Name $_ | Out-Null

    $HTML = "<pre>/$_</pre>"
    $HTML += gc C:\inetpub\wwwroot\default.aspx -Raw
    $HTML > C:\inetpub\wwwroot\$_\default.aspx
}

# Remove default iisstart.htm file
Remove-Item "C:\inetpub\wwwroot\iisstart.htm"

# Configure IIS HTTPS binding using previously imported self signed certificate
$Cert = Get-ChildItem Cert:\LocalMachine\My\ | ? Subject -like "*leemicha.biz*"
New-WebBinding -Name "Default Web Site" -Protocol https -Port 443
(Get-WebBinding -Name "Default Web Site" -Protocol https -Port 443).AddSslCertificate($Cert.Thumbprint, "my")

#Remove http binding
#Remove-WebBinding -Protocol http -Port 80
