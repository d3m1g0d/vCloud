<#
.SYNOPSIS
  Import vCloud edge NAT rules, firewall rules, and static routes from 
  CSV files into a given edge.
.DESCRIPTION
  This program imports vCloud edge NAT rules, firewall rules, and static routes
  from a  previously exported edge configuration.
  The CSV files must be saved in the directory, where the program is executed.
  It only import user-defined rules, no rules created by any services (e.g. VPN
  tunnels).
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
.PARAMETER myCiServer
  The name of the cloud server to connect to.
.EXAMPLE
  PS> .\vcd-edge-import.ps1 -Org foobar -SourceEdge foobar_gw_01 -TargetEdge foobar_gw_02
  Executes the program for edge foobar_gw_01 in vOrg foobar.
.NOTES
  Author: Adrian Heißler <adrian.heissler@t-systems.at>
  29.04.2020: Version 1.0 - Initial revision.
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
$edgeGatewayID = $EdgeGateway.id.split(":")[-1]
$edgeGatewayID
#endregion get edge

#region import nat configuration
Write-Host "Build edge nat config from csv file" -Foregroundcolor cyan
Import-Csv -Path .\$($SourceEdge)-NATRules.csv -ErrorAction Stop | Foreach-Object {
	Write-Host $_
	$Rule = "" | Select-Object ID, action, vnic, originalAddress, translatedAddress, loggingEnabled, enabled, description, protocol, originalPort, translatedPort
	
	$NewRule = '
	<natRule>
		<ruleType>user</ruleType>
		<action>' + $_.action + '</action>
		<vnic>' + $_.vnic + '</vnic>
		<originalAddress>' + $_.originalAddress + '</originalAddress>
		<translatedAddress>' + $_.translatedAddress + '</translatedAddress>
		<loggingEnabled>' + $_.loggingEnabled + '</loggingEnabled>
		<enabled>' + $_.enabled + '</enabled>
		<description>' + $_.description + '</description>
		<protocol>' + $_.protocol + '</protocol>
		<originalPort>' + $_.originalPort + '</originalPort>
		<translatedPort>' + $_.translatedPort + '</translatedPort>
	</natRule>
	'
	$NATRulesXML += $NewRule
}

$GoXML = '<natRules>'
$GoXML += $NATRulesXML
$GoXML += '</natRules>'
#$GoXML
Write-Host "Activate nat service on edge" -Foregroundcolor cyan
$CIServer = $global:DefaultCIServers.Name | Where-Object { $edgeGateway.href -match $_.ServiceUri }
$invokeURI = "https://$CIServer/network/edges/$edgeGatewayID/nat/config/rules"
try{ 
	$null = Invoke-vCloud -URI $invokeURI -Body $GoXML -ContentType 'application/*+xml' -Method POST | Out-Null
}
catch {
	throw "Cannot congfigure edge firewall service"
}
#endregion import nat configuration

#region import firewall configuration
Write-Host "Build edge firewall config from csv file" -Foregroundcolor cyan
Import-Csv -Path .\$($SourceEdge)-FirewallRules.csv -ErrorAction Stop | Foreach-Object {
	Write-Host $_
	$Rule = "" | Select-Object ID, IsEnabled, Description, Source, Destination, Service, EnableLogging, Policy
	
	if ($_.Source) {
		$sourceXML = '<source>'
		$ipAddresses = $_.Source.Split(" ")
		foreach ($ipAddr in $ipAddresses) {
			$sourceXML += "<ipAddress>$ipAddr</ipAddress>"
		}
		$sourceXML += '</source>'
	}
	if ($_.Destination) {
		$destinationXML = '<destination>'
		$ipAddresses = $_.Destination.Split(" ")
		foreach ($ipAddr in $ipAddresses) {
			$destinationXML += "<ipAddress>$ipAddr</ipAddress>"
		}
		$destinationXML += '</destination>'
	}

	if ($_.Service) {
		if ($_.Service -eq "Icmp") {
			$serviceXML = "<service>
              <protocol>Icmp</protocol>
              <icmpType>any</icmpType>
            </service>"
		}
		elseif ($_.Service -eq "Any") {
			$serviceXML = "<service>
              <protocol>Any</protocol>
            </service>"
		}
		else {
			$services = $_.Service.Split(" ")
			$ServiceXML = ''
			foreach ($service in $services) {
				$s = $service.Split(":")		
				$ServiceXML += '<service>'
				$ServiceXML += '<protocol>' + $s[0] + '</protocol>'
				$ServiceXML += '<port>' + $s[1] + '</port>'
				$ServiceXML += '<sourcePort>' + $s[2] + '</sourcePort>'
				$ServiceXML += '</service>'
			}
		}
	}
	
	$NewRule = '
	<firewallRule>
    <name>' + $_.Description + '</name>
    <ruleType>user</ruleType>
    <enabled>' + $_.IsEnabled + '</enabled>
    <loggingEnabled>' + $_.EnableLogging + '</loggingEnabled>
    <action>' + $_.Policy + '</action>
	' + $sourceXML + '
    ' + $destinationXML + '
    <application>
    ' + $serviceXML + '
    </application>
    </firewallRule>
	'
	$FWRulesXML += $NewRule
}

$GoXML = '<firewallRules>'
$GoXML += $FWRulesXML
$GoXML += '</firewallRules>'
$GoXML
$GoXML > .\fw.xml
Write-Host "Activate firewall service on edge" -Foregroundcolor cyan
$CIServer = $global:DefaultCIServers.Name | Where-Object { $edgeGateway.href -match $_.ServiceUri }
$invokeURI = "https://$CIServer/network/edges/$edgeGatewayID/firewall/config/rules"
try{ 
	$null = Invoke-vCloud -URI $invokeURI -Body $GoXML -ContentType 'application/*+xml' -Method POST | Out-Null
}
catch {
	throw "Cannot congfigure edge firewall service"
}
#endregion import firewall configuration

#region import static routes
Write-Host "Build edge default route config from csv file" -Foregroundcolor cyan
Import-Csv -Path .\$($SourceEdge)-DefaultRoute.csv -ErrorAction Stop | Foreach-Object {
	Write-Host $_
	$Route = "" | Select-Object vnic, mtu, gatewayAddress, adminDistance
	
	$DefaultRouteXML = '
	<defaultRoute>
		<vnic>' + $_.vnic + '</vnic>
		<mtu>' + $_.mtu + '</mtu>
		<gatewayAddress>' + $_.gatewayAddress + '</gatewayAddress>
		<adminDistance>' + $_.adminDistance + '</adminDistance>
	</defaultRoute>
	'
}

Write-Host "Build edge static route config from csv file" -Foregroundcolor cyan
Import-Csv -Path .\$($SourceEdge)-StaticRoutes.csv -ErrorAction Stop | Foreach-Object {
	Write-Host $_
	$Route = "" | Select-Object mtu, description, vnic, network, nextHop, adminDistance
	
	$NewRoute = '
	<route>
		<mtu>' + $_.mtu + '</mtu>
		<description>' + $_.description + '</description>
		<type>user</type>
		<vnic>' + $_.vnic + '</vnic>
		<network>' + $_.network + '</network>
		<nextHop>' + $_.nextHop + '</nextHop>
		<adminDistance>' + $_.adminDistance + '</adminDistance>
	</route>
	'
	$RoutesXML += $NewRoute
}

$GoXML = '<staticRouting>'
$GoXML += $DefaultRouteXML
$GoXML += '<staticRoutes>'
$GoXML += $RoutesXML
$GoXML += '</staticRoutes>'
$GoXML += '</staticRouting>'
#$GoXML
Write-Host "Activate static routing service on edge" -Foregroundcolor cyan
$CIServer = $global:DefaultCIServers.Name | Where-Object { $edgeGateway.href -match $_.ServiceUri }
$invokeURI = "https://$CIServer/network/edges/$edgeGatewayID/routing/config/static"
try{ 
	$null = Invoke-vCloud -URI $invokeURI -Body $GoXML -ContentType 'application/*+xml' -Method PUT | Out-Null
}
catch {
	throw "Cannot congfigure edge static routing service"
}
#endregion import static routes

Disconnect-CIServer $myCiServer -Confirm:$false
