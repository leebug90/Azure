# Allow ICMP
netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4:8,any dir=in action=allow
netsh advfirewall firewall add rule name="Allow ICMPv6" protocol=icmpv6:8,any dir=in action=allow

# Install IIS with ASP.Net support
Install-WindowsFeature -name Web-Server, Web-Asp-Net45 -IncludeManagementTools

# Create a default file containing WAN IP, ipconfig output, and a dump of request headers
$HTML = "<pre>" + $ENV:COMPUTERNAME + "<br/>"
$HTML += "WAN IP: $(irm ifconfig.me) <br/><hr/>"
$HTML += "Request headers: <br/>"
$HTML += '<%= Request.Headers.ToString().Replace("&","<br/>") %></pre>'
$HTML > C:\inetpub\wwwroot\default.aspx

# Install Certificate
mkdir c:\Temp1
Add-Content -Value "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" -Path C:\temp1\pfx-encoded-bytes.txt
certutil -decode c:\temp1\pfx-encoded-bytes.txt c:\temp1\backend.pfx
certutil -f -p Password1 -importpfx c:\temp1\backend.pfx

# Remove default iisstart.htm file
Remove-Item "C:\inetpub\wwwroot\iisstart.htm"

# Configure IIS HTTPS binding using previously imported self signed certificate
$Cert = Get-ChildItem Cert:\LocalMachine\My\ | ? Subject -eq "CN=backend.fabrikam.com"
New-WebBinding -Name "Default Web Site" -Protocol https -Port 443
(Get-WebBinding -Name "Default Web Site" -Protocol https -Port 443).AddSslCertificate($Cert.Thumbprint, "my")

# Remove http binding
Remove-WebBinding -Protocol http -Port 80
