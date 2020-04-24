<#
.SYNOPSIS
  Export vCloud edge NAT rules, firewall rules, and static routes to CSV files.
.DESCRIPTION
  This program creates CSV exports of a given vCloud edge NAT, firewall rules
  and static routes.
  The CSV files are saved in the directory, where the program has been executed.
  It only exports user-defined rules, no rules created by any services (e.g. VPN
  tunnels).
.PARAMETER Org 
  The vOrg to log in.  User credentials must be provided during script execution.
.PARAMETER Edge
  The name of the edge which configuration should be exported.
.PARAMETER myCiServer
  The name of the cloud server to connect to.
.EXAMPLE
  PS> .\vcd-edge-export.ps1 -Org foobar -Edge foobar_gw_01 -myCiServer cloud.t-systems.at
  Executes the program for edge foobar_gw_01 in vOrg foobar.
.NOTES
  Author: Adrian Heißler <adrian.heissler@t-systems.at>
  24.04.2020: Version 1.2 - Added export of static routes.
  07.09.2019: Version 1.1 - Fixed API version in get-edgeconfig with vCD 9.1.
  11.12.2018: Version 1.0 - Initial revision.
#>
Param (
	[Parameter(Mandatory=$False, ValueFromPipeline=$False, HelpMessage="Enter the vCloud organization name")]
	[ValidateNotNullorEmpty()]
	[String] $Org,
	[Parameter(Mandatory=$True, ValueFromPipeline=$False, HelpMessage="Enter the name of the source edge")]
	[ValidateNotNullorEmpty()]
	[String] $Edge,
	[Parameter(Mandatory=$False, ValueFromPipeline=$False, HelpMessage="Enter the vCloud Director hostname")]
	[ValidateNotNullorEmpty()]
	[String] $myCiServer = "cloud.t-systems.at"
)

function Get-EdgeConfig ($EdgeGateway) {
    $Edgeview = $EdgeGateway | Get-CIView
    $webclient = New-Object system.net.webclient
    $webclient.Headers.Add("x-vcloud-authorization",$EdgeView.Client.SessionKey)
    $webclient.Headers.Add("accept",$EdgeView.Type + ";version=27.0")

    [xml]$EdgeConfXml = $webclient.DownloadString($EdgeView.href)

    $EdgeConfXml 
}

function Get-EdgeNATRules ($EdgeConfXml) {
	$NATRules = $EdgeConfXml.EdgeGateway.Configuration.EdgegatewayServiceConfiguration.NatService.Natrule

    $Rules = @()
    if ($NATRules){
		$NATRules | ForEach-Object {
			$NewRule = New-Object PSObject -Property @{
				ID = $_.Id;
				AppliedOn = $_.GatewayNatRule.Interface.Name;
				Href = $_.GatewayNatRule.Interface.href;
				Type = $_.RuleType;
				OriginalIP = $_.GatewayNatRule.OriginalIP;
				OriginalPort = $_.GatewayNatRule.OriginalPort;
				TranslatedIP = $_.GatewayNatRule.TranslatedIP;
				TranslatedPort = $_.GatewayNatRule.TranslatedPort;
				Enabled = $_.IsEnabled;
				Protocol = $_.GatewayNatRule.Protocol
			}
	        $Rules += $NewRule
	    }
	}
    $Rules
}

function Get-EdgeFirewallRules ($EdgeConfXml) {
    $FirewallRules = $EdgeConfXml.EdgeGateway.Configuration.EdgegatewayServiceConfiguration.FirewallService.FirewallRule
	$Rules = @()
	$Row = 1
    if ($FirewallRules){
		$FirewallRules | ForEach-Object {
			if ($_.Protocols.Any) { $Protocols = "Any" } 
			elseif ($_.Protocols.Tcp) {	$Protocols = "TCP" } 
			elseif ($_.Protocols.Udp) { $Protocols = "UDP" } 
			elseif ($_.Protocols.Icmp) { $Protocols = "ICMP" } 
			else { $Protocols = "Any" }
	        $NewRule = New-Object PSObject -Property @{
				ID = $Row
				IsEnabled = $_.IsEnabled
				Description = $_.Description
				Policy = $_.Policy
				Protocols = $Protocols
				SourceIp = $_.SourceIp
				SourcePortRange = $_.SourcePortRange
				DestinationIp = $_.DestinationIp
				DestinationPortRange = $_.DestinationPortRange
				MatchOnTranslate = $_.MatchOnTranslate
				EnableLogging = $_.EnableLogging
			}
	        $Rules += $NewRule
			$Row++
	    }
	}
    $Rules
}

function Get-EdgeStaticRoutes ($EdgeConfXml) {
	$StaticRoutes = $EdgeConfXml.EdgeGateway.Configuration.EdgegatewayServiceConfiguration.StaticRoutingService.StaticRoute
	
	$Routes = @()
	$Row = 1
    if ($StaticRoutes){
		$StaticRoutes | ForEach-Object {
	        $NewRoute = New-Object PSObject -Property @{
				ID = $Row
				Name = $_.Name
				Network = $_.Network
				NextHopIp = $_.NextHopIp
				GatewayInterfaceName = $_.GatewayInterface.name
				GatewayInterfaceHref = $_.GatewayInterface.href
			}
	        $Routes += $NewRoute
			$Row++
	    }
	}
    $Routes
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
[Array]$EdgeGateway = Search-Cloud -QueryType EdgeGateway -Name $Edge -ErrorAction Stop
if ($EdgeGateway.Count -gt 1) {
	throw "Multiple edges found!"
}
elseif ($EdgeGateway.Count -lt 1) {
	throw "No edge found!"
}
Write-Host $EdgeGateway[0].Id
#endregion get edge

#region get configuration
Write-Host "Get edge config" -Foregroundcolor cyan
$EdgeConfig = Get-EdgeConfig -EdgeGateway $EdgeGateway[0]

Write-Host "Get edge NAT rules" -Foregroundcolor cyan
$EdgeNATRules = Get-EdgeNATRules -EdgeConfXml $EdgeConfig
$EdgeNATRules
Write-Host "Export edge NAT rules to .\$($Edge)-NATRules.csv" -Foregroundcolor cyan
$EdgeNATRules | Export-Csv -Path .\$($Edge)-NATRules.csv -NoType

Write-Host "Get edge firewall rules" -Foregroundcolor cyan
$EdgeFirewallRules = Get-EdgeFirewallRules -EdgeConfXml $EdgeConfig
$EdgeFirewallRules
Write-Host "Export edge firewall rules to .\$($Edge)-FirewallRules.csv" -Foregroundcolor cyan
$EdgeFirewallRules | Export-Csv -Path .\$($Edge)-FirewallRules.csv -NoType

Write-Host "Get edge static routes" -Foregroundcolor cyan
$EdgeStaticRoutes = Get-EdgeStaticRoutes -EdgeConfXml $EdgeConfig 
$EdgeStaticRoutes
Write-Host "Export edge static routes to .\$($Edge)-StaticRoutes.csv" -Foregroundcolor cyan
$EdgeStaticRoutes | Export-Csv -Path .\$($Edge)-StaticRoutes.csv -NoType
#endregion get configuration

Disconnect-CIServer $myCiServer -Confirm:$false
