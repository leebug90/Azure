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

# Install Certificate - leebug.biz
mkdir c:\Temp1
Add-Content -Value "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" -Path C:\temp1\pfx-encoded-bytes.txt
certutil -decode c:\temp1\pfx-encoded-bytes.txt c:\temp1\backend.pfx
certutil -f -p poshacme -importpfx c:\temp1\backend.pfx

# Remove default iisstart.htm file
Remove-Item "C:\inetpub\wwwroot\iisstart.htm"

# Configure IIS HTTPS binding using previously imported self signed certificate
$Cert = Get-ChildItem Cert:\LocalMachine\My\ | ? Subject -eq "CN=*.leebug.biz"
New-WebBinding -Name "Default Web Site" -Protocol https -Port 443
(Get-WebBinding -Name "Default Web Site" -Protocol https -Port 443).AddSslCertificate($Cert.Thumbprint, "my")

# Remove http binding
Remove-WebBinding -Protocol http -Port 80
