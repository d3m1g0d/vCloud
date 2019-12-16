<#
.SYNOPSIS
  Import vCloud edge NAT rules and firewall from CSV files into given edge.
.DESCRIPTION
  This program creates CSV exports of a given vCloud edge NAT and firewall rules.
  The CSV files are saved in the directory, where the program has been executed.
  It only exports standard rules, no rules related to VPN tunnels.
  Before executing the program, make sure that the rules in the CSV files fit to 
  the actual configuration of the edge where the rules should be imported 
  (e.g. IP addresses).
.PARAMETER Org 
  The vOrg to log in.  User credentials must be provided during script execution.
.PARAMETER TargetEdge
  The name of the target edge, on which the configuration should be imported.
.PARAMETER SourceEdge
  The name of the source edge, from which the configuration has been exported.
  It is used to look up the CSV files in the current directory.
 
.EXAMPLE
  PS> .\vcd-edge-import.ps1 -Org foobar -SourceEdge foobar_gw_01 -TargetEdge foobar_gw_02  -myCiServer cloud.t-systems.at
  Executes the program for edge foobar_gw_01 in vOrg foobar.
.NOTES
  Author: Adrian Heißler <adrian.heissler@t-systems.at>
  11.12.2018: Version 1.0 - Initial revision.
#>
Param (
	[Parameter(Mandatory=$False, ValueFromPipeline=$False, HelpMessage="Enter the vCloud organization name")]
	[ValidateNotNullorEmpty()]
	[String] $Org,
	[Parameter(Mandatory=$True, ValueFromPipeline=$False, HelpMessage="Enter the name of the target edge")]
	[ValidateNotNullorEmpty()]
	[String] $TargetEdge,
	[Parameter(Mandatory=$True, ValueFromPipeline=$False, HelpMessage="Enter the name of the source edge")]
	[ValidateNotNullorEmpty()]
	[String] $SourceEdge,
	[Parameter(Mandatory=$False, ValueFromPipeline=$False, HelpMessage="Enter the vCloud Director hostname")]
	[ValidateNotNullorEmpty()]
	[String] $myCiServer = "cloud.t-systems.at"
)

Function Invoke-vCloud(
[Parameter(Mandatory=$true)][uri]$URI,      # We must specify the API endpoint
[string]$ContentType,                       # Optional ContentType for returned XML
[string]$Method = 'GET',                    # HTTP verb to use (default 'GET')
[string]$ApiVersion = '27.0',               # vCloud Director API version (default to vCD 8.20 - version 27.0)
[string]$Body,                              # Any body document to be submitted to the API
[int]$Timeout = 40,                         # Timeout in seconds to wait for API response (by default)
[string]$vCloudToken                        # If not already authenticated using Connect-CIServer (PowerCLI) allow us to specify a token
) {
    $mySessionID = ($Global:DefaultCIServers | Where-Object { $_.Name -eq $URI.Host }).SessionID
    if (!$mySessionID) {                    # If we didn't find an existing PowerCLI session for our URI
        if ($vCloudToken) {                 # But we have been passed a x-vcloud-authorization token, use that
            $mySessionID = $vCloudToken
        } else {                            # Otherwise we have no authentication mechanism available so quit
            Write-Error ("No existing session found and no vCloudToken specified, cannot authenticate, exiting.")
            Return
        }
    } # $mySessionID not set

    # If ContentType or Body are not specified, remove the variable definitions so they won't get passed to Invoke-RestMethod:
    if (!$ContentType) { Remove-Variable ContentType }
    if (!$Body) { Remove-Variable Body }

    # Configure HTTP headers for this request:
    $Headers = @{ "x-vcloud-authorization" = $mySessionID; "Accept" = 'application/*+xml;version=' + $ApiVersion }

    # Submit API request:
    Try {
        [xml]$response = Invoke-RestMethod -Method $Method -Uri $URI -Headers $Headers -Body $Body -ContentType $ContentType -TimeoutSec $Timeout
    }
    Catch {                                 # Something went wrong, so return error information and exit:
        Write-Warning ("Invoke-vCloud Exception: $($_.Exception.Message)")
        if ( $_.Exception.ItemName ) { Write-Warning ("Failed Item: $($_.Exception.ItemName)") }
        Return
    }

    # Return API response to caller
    Return $response
}

#region connect-ciserver
if (-not $global:DefaultCIServers) {
	try{
		Write-Host "Connect to CIServer" -Foregroundcolor cyan
		$CIServer = Connect-CIServer $myCiServer -Org $Org -ErrorAction:stop
	}
	catch{
		throw "Cannot connect! $_.Exception.Message"
	}
}

if ($Org -eq "") { $Org = $global:DefaultCIServers[0].Org }
#endregion connect-ciserver

#region get edge
Write-Host "Get edge" -Foregroundcolor cyan
[Array]$EdgeGateway = Search-Cloud -QueryType EdgeGateway -Name $TargetEdge -ErrorAction Stop
if ($EdgeGateway.Count -gt 1) {
	throw "Multiple edges found!"
}
elseif ($EdgeGateway.Count -lt 1) {
	throw "No edge found!"
}
$EdgeView = $EdgeGateway[0] | Get-CIView
Write-Host $EdgeView.Id
#endregion get edge

#region import nat configuration
Write-Host "Build edge nat config from csv file" -Foregroundcolor cyan
Import-Csv -Path .\$($SourceEdge)-NATRules.csv -ErrorAction Stop | Foreach-Object {
	Write-Host $_
	$Rule = "" | Select-Object ID, AppliedOn, Description, Type, OriginalIP, OriginalPort, TranslatedIP, TranslatedPort, Enabled, Protocol, NetworkHref

	$Rule.ID = $_.ID
	$Rule.appliedon = $_.appliedOn
	$Rule.type = $_.Type
	$Rule.originalip = $_.OriginalIP
	$Rule.originalport = $_.OriginalPort
	$Rule.translatedip = $_.TranslatedIP
	$Rule.translatedport = $_.TranslatedPort
	$Rule.enabled = $_.Enabled.ToLower()
	$Rule.protocol = $_.Protocol
	$Rule.description = $_.Description
	if($Rule.protocol -eq "TCP/UDP") { $Rule.protocol="tcpudp" }
	if($Rule.type -eq "SNAT") { 
		$Rule.originalport = "Any"
		$Rule.translatedport = "Any"
        $Rule.protocol = "Any"
	}
	$Rule.networkhref = ($EdgeView.Configuration.GatewayInterfaces.GatewayInterface.network | where {$_.name -eq $Rule.appliedon}).href

	$NewRule = '<NatRule>
		<Description>' + $Rule.description + '</Description>
		<RuleType>' + $Rule.type + '</RuleType>
		<IsEnabled>' +  $Rule.enabled + '</IsEnabled>
		<Id>' + $Rule.ID + '</Id>
		<GatewayNatRule>
			<Interface href="' + $Rule.networkhref + '"/>
			<OriginalIp>' + $Rule.originalip + '</OriginalIp>
			<OriginalPort>' + $Rule.originalport + '</OriginalPort>
			<TranslatedIp>' + $Rule.translatedip + '</TranslatedIp>
			<TranslatedPort>' + $Rule.translatedport + '</TranslatedPort>
			<Protocol>' + $Rule.protocol + '</Protocol>'
		if($Rule.protocol -eq "ICMP") {
			$NewRule = $NewRule + '
			<IcmpSubType>any</IcmpSubType>'
		}
		$NewRule = $NewRule + '
		</GatewayNatRule>
	</NatRule>
	'
	$RulesXML += $NewRule
}
$GoXML = '<?xml version="1.0" encoding="UTF-8"?>
<EdgeGatewayServiceConfiguration xmlns="http://www.vmware.com/vcloud/v1.5" >
	<NatService>
		<IsEnabled>true</IsEnabled>
	'
$GoXML += $RulesXML
$GoXML += '</NatService>
</EdgeGatewayServiceConfiguration>'

$CIServer = $global:DefaultCIServers.Name | Where-Object { $edgeGateway.href -match $_.ServiceUri }
$edgeGatewayID = $EdgeView.id.Split(':')[3]
$invokeURI = "https://$CIServer/api/admin/edgeGateway/$edgeGatewayID/action/configureServices"
try{ 
	$null = Invoke-vCloud -URI $invokeURI -Body $GoXML -ContentType 'application/vnd.vmware.admin.edgeGatewayServiceConfiguration+xml' -Method POST | Out-Null
}
catch {
	throw "Cannot congfigure edge nat service"
}

while ((Search-Cloud -QueryType EdgeGateway -Name $TargetEdge -Verbose:$False).IsBusy -eq $True) {
	$i++
	Start-Sleep 1
	if ($i -gt 120) { Write-Error "Configure nat service"; break }
	Write-Progress -Activity "Configure nat service" -Status "Wait for edge to become ready..."
}
Write-Progress -Activity "Configure nat service" -Completed
#endregion import nat configuration

#region import firewall configuration
Write-Host "Build edge firewall config from csv file" -Foregroundcolor cyan
$EdgeView = $EdgeGateway[0] | Get-CIView

$FwService = New-Object VMware.VimAutomation.Cloud.Views.FirewallService
$FwService.DefaultAction = "drop"
$FwService.LogDefaultAction = $False
$FwService.IsEnabled = $True
$FwService.FirewallRule = @()
$Row = 1

Import-Csv -Path .\$($SourceEdge)-FirewallRules.csv -ErrorAction Stop | Foreach-Object {
	Write-Host $_
	$FwService.FirewallRule += New-Object VMware.VimAutomation.Cloud.Views.FirewallRule
	$Row = $_.ID - 1

	$FwService.FirewallRule[$Row].Description = $_.Description
	$FwService.FirewallRule[$Row].Policy = $_.Policy
	$FwService.FirewallRule[$Row].SourceIp = $_.SourceIp
	$FwService.FirewallRule[$Row].DestinationIp = $_.DestinationIp
       
	if ($_.IsEnabled -eq "True") { $FwService.FirewallRule[$Row].IsEnabled = $True }
	else { $FwService.FirewallRule[$Row].IsEnabled = $False }
	if ($_.MatchOnTranslate -eq "True") { $FwService.FirewallRule[$Row].MatchOnTranslate = $True } 
	else { $FwService.FirewallRule[$Row].MatchOnTranslate = $False }
	if ($_.EnableLogging -eq "True") { $FwService.FirewallRule[$Row].EnableLogging = $True } 
	else { $FwService.FirewallRule[$Row].EnableLogging = $False }
	
	if ($_.SourcePortRange -eq "Any") {
		$FwService.FirewallRule[$Row].SourcePort = -1
		$FwService.FirewallRule[$Row].SourcePortRange = "Any"
	}
	else {
		$FwService.FirewallRule[$Row].SourcePort = $_.SourcePort
		$FwService.FirewallRule[$Row].SourcePortRange = $_.SourcePortRange
	}
	if ($_.DestinationPortRange -eq "Any") {
		$FwService.FirewallRule[$Row].Port = -1
		$FwService.FirewallRule[$Row].DestinationPortRange = "Any"
	}
	else {
		$FwService.FirewallRule[$Row].Port = $_.DestinationPort
		$FwService.FirewallRule[$Row].DestinationPortRange = $_.DestinationPortRange
	}
	 
	$FwService.FirewallRule[$Row].Protocols = New-Object VMware.VimAutomation.Cloud.Views.FirewallRuleTypeProtocols
	switch ($_.Protocols) {
		"Any" { $FwService.FirewallRule[$Row].Protocols.Any = $True }
		"TCP" { $FwService.FirewallRule[$Row].Protocols.Tcp = $True	}
		"UDP" {	$FwService.FirewallRule[$Row].Protocols.Udp = $True	}
		"ICMP" { $FwService.FirewallRule[$Row].Protocols.Icmp = $True }
		default { $FwService.FirewallRule[$Row].Protocols.Any = $True }
	}
}
$null = $EdgeView.ConfigureServices_Task($FwService)

while ((Search-Cloud -QueryType EdgeGateway -Name $TargetEdge -Verbose:$False).IsBusy -eq $True) {
	$i++
	Start-Sleep 1
	if ($i -gt 120) { Write-Error "Configure firewall service"; break }
	Write-Progress -Activity "Configure firewall service" -Status "Wait for edge to become ready..."
}
Write-Progress -Activity "Configure firewall service" -Completed
#endregion import firewall configuration

Disconnect-CIServer $myCiServer -Confirm:$false
