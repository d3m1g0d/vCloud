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
  PS> .\vcd-edge-export.ps1 -Org foobar -Edge foobar_gw_01
  Executes the program for edge foobar_gw_01 in vOrg foobar.
.NOTES
  Author: Adrian Heißler <adrian.heissler@t-systems.at>
  29.04.2020: Version 1.0 - Initial revision.
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

function Get-EdgeConfig ($EdgeGatewayID) {
    $webclient = New-Object system.net.webclient
    $webclient.Headers.Add("x-vcloud-authorization",$CIServer.SessionId)
    $webclient.Headers.Add("accept","application/*+xml;version=27.0")

    [xml]$EdgeConfXml = $webclient.DownloadString("https://$myCiServer/network/edges/$EdgeGatewayID")

    $EdgeConfXml 
}

function Get-EdgeNATRules ($EdgeConfXml) {
	$NATRules = $EdgeConfXml.edge.features.nat.natRules.natRule

    $Rules = @()
    if ($NATRules){
		$NATRules | ForEach-Object {
			if ($_.ruleType -eq "user") {   
				$NewRule = [pscustomobject] @{
					ID = $_.ruleId
					action = $_.action
					vnic = $_.vnic
					originalAddress = $_.originalAddress
					translatedAddress = $_.translatedAddress
					loggingEnabled = $_.loggingEnabled
					enabled = $_.enabled
					description = $_.description
					protocol = $_.protocol
					originalPort = $_.originalPort
					translatedPort = $_.translatedPort
				}
				$Rules += $NewRule
			}
		}
	}
    $Rules
}

function Get-EdgeFirewallRules ($EdgeConfXml) {
    $FirewallRules = $EdgeConfXml.edge.features.firewall.firewallRules.firewallRule
	$Rules = @()
    if ($FirewallRules){
		$FirewallRules | ForEach-Object {
			if ($_.ruleType -eq "user") { 
				if ($_.description) { $description = $_.description }
				else { $description = $_.name }
				
				if ($_.source.vnicGroupId) { $source = $_.source.vnicGroupId } 
				else { 
					$source = ''
					foreach ($s in $_.source.ipAddress) { $source += "$s " }
					if ($source.Chars($source.Length - 1) -eq ' ') { $source = ($source.TrimEnd(' ')) }
				}
				
				if ($_.destination.vnicGroupId) { $destination = $_.destination.vnicGroupId } 
				else { 
					$destination = ''
					foreach ($s in $_.destination.ipAddress) { $destination += "$s " }
					if ($destination.Chars($destination.Length - 1) -eq ' ') { $destination = ($destination.TrimEnd(' ')) }
				}
				
				$service = ''
				foreach ($s in $_.application.service) {
					if ($s.protocol -eq 'Icmp' -or $s.protocol -eq 'any') { $service = $s.protocol }
					else { $service += $s.protocol + ':' + $s.port + ':' + $s.sourceport + ' ' }
				}
				if ($service.Chars($service.Length - 1) -eq ' ') { $service = ($service.TrimEnd(' ')) }
			
				$NewRule = [pscustomobject] @{
					ID = $_.ruleTag
					IsEnabled = $_.enabled
					Description = $description
					Source = $source
					Destination = $destination
					Service = $service
					EnableLogging = $_.loggingEnabled
					Policy = $_.action
				}
				$Rules += $NewRule
			}
	    }
	}
    $Rules
}

function Get-EdgeStaticRoutes ($EdgeConfXml) {
	$StaticRoutes = $EdgeConfXml.edge.features.routing.staticRouting.staticRoutes.route
	
	$Routes = @()
    if ($StaticRoutes){
		$StaticRoutes | ForEach-Object {
			if ($_.type -eq "user") { 
				if (!$_.mtu) { $mtu = 1500} else { $mtu = $_.mtu }
				$NewRoute = [pscustomobject] @{
					mtu = $mtu
					description = $_.description
					vnic = $_.vnic
					network = $_.network
					nextHop = $_.nextHop
					adminDistance = $_.adminDistance
				}
				$Routes += $NewRoute
			}
	    }
	}
    $Routes
}

function Get-EdgeDefaultRoute ($EdgeConfXml) {
	$defaultRoute = $EdgeConfXml.edge.features.routing.staticRouting.defaultRoute
	
	$Routes = @()
    if ($defaultRoute){
		$defaultRoute | ForEach-Object {
			if (!$_.mtu) { $mtu = 1500} else { $mtu = $_.mtu }
			$NewRoute = [pscustomobject] @{
				vnic = $_.vnic
				mtu = $mtu
				gatewayAddress = $_.gatewayAddress
				adminDistance = $_.adminDistance
			}
			$Routes += $NewRoute
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
$EdgeConfig = Get-EdgeConfig -EdgeGateway $EdgeGateway.id.split(":")[-1]

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

Write-Host "Get edge default route" -Foregroundcolor cyan
$EdgeDefaultRoute = Get-EdgeDefaultRoute -EdgeConfXml $EdgeConfig
$EdgeDefaultRoute
Write-Host "Export edge default route to .\$($Edge)-DefaultRoute.csv" -Foregroundcolor cyan
$EdgeDefaultRoute | Export-Csv -Path .\$($Edge)-DefaultRoute.csv -NoType
#endregion get configuration

Disconnect-CIServer $myCiServer -Confirm:$false
