[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [String] $Domain,

    [Parameter(Mandatory)]
    [String] $Room,

    [Parameter(Mandatory)]
    [Int] $Hosts,

    [Parameter()]
    [String] $Suffix = "03",

    [Parameter()]
    [Switch] $Defaults
)

$default_groups = @("ACL_RD-RAP", "ACL_User", "GG_User", "GG")

# add members to groups
$members_list = @(
    [PSCustomObject]@{
        group = "ACL_RD-RAP";
        members = "GG"
    }
    [PSCustomObject]@{
        group = "ACL_User";
        members = "GG_User"
    }
    [PSCustomObject]@{
        group = "GG_User";
        members = @("RDTest")
    }
)

$ou_list = @(
    [PSCustomObject]@{
        group = "ACL_RD-RAP";
        ou = @("OU_R$Room", "OU_ACL-Gruppen", "OU_Gruppen")
    }
    [PSCustomObject]@{
        group = "ACL_User";
        ou = @("OU_R$Room", "OU_ACL-Gruppen", "OU_Gruppen")
    }
    [PSCustomObject]@{
        group = "GG_User";
        ou = @("OU_R$Room", "OU_GlobaleGruppen", "OU_Gruppen")
    }
    [PSCustomObject]@{
        group = "GG";
        ou = @("OU_R$Room", "OU_GlobaleGruppen", "OU_Gruppen")
    }
)

# suffix was passed as empty
if ($Suffix.Trim()) { $Suffix = "_$Suffix" }

# prompt for prefixes
$default_groups_str = $default_groups -join ", "
if (!$Defaults) {
    $groups = (Read-Host -Prompt "`n[>] Please provide desired group prefixes.`n    [Default]: $default_groups_str`n    Accept defaults with [ENTER] or write names.`n    Separate with comma and space").Split(",").Trim()
}
# defaults were accepted
if (!$groups) {
    $groups = $default_groups
    $groups_note = "`n    Defaults were accepted."
}
# user feedback
Write-Output ($groups_note, "`n    ", ($groups.Count * $Hosts), "groups with", $groups.Count, "different prefixes will be created." -join " ")

# sort to craete GG_ before ACL_
$groups = $groups | Sort-Object -Descending
# pre-construct dc path for group creation
$dc_path = (",DC=", ($Domain.Split('.') -join ",DC=") -join "")
# filter errors for log file
filter stamp {"$(Get-Date -Format G): $_"}
# error counter for user feedback
$error_counter = 0

foreach ($prefix in $groups) {

    # Dieses Präfix hat eine default OU vordefiniert
    if ($ou_list.group.Contains($prefix)) {
        $ou = $ou_list | Where-Object {$_.group -eq $prefix} | Select-Object -ExpandProperty ou
        $ou_note = "`n    [Default] organizational units found for prefix [$prefix]: $ou`n    Accept with [ENTER] or write new ones."
    }
    # prompt for ou path
    if (!$Defaults) {
        $ou_prompt = (Read-Host -Prompt "`n[>] Please provide the OU path for groups with prefix [$prefix].$ou_note`n    Write from child (left) to parent (right).`n    Only provide names, the script will add keys.`n    Separate with comma and space").Split(",").Trim()
    }
    # user did provide input
    if ($ou_prompt) { $ou = $ou_prompt }

    # pre-construct ou path for group creation
    $ou_path = (",OU=", ($ou.Split(',').Trim() -join ",OU=") -join "")
    $path = ($ou_path, $dc_path -join "")

    # need to create parents first
    [Array]::Reverse($ou)
    $ou_queue = $dc_path

    # if necessary create the OUs by iterating over the path
    for ($i = 0; $i -lt $ou.Count; $i++) {

        # construct distinguishedName and parent path
        $separator = if ($i -gt 0) { "," }
        if ($i -le 0) {
            $ou_parents = $ou_queue.substring(1)
            $ou_queue = ("OU=", $ou[$i], $separator, $ou_queue -join "")
        } else {
            $ou_parents = ("OU=", $ou[$i-1], $separator, $ou_parents -join "")
            $ou_queue = ("OU=", $ou[$i], $separator, $ou_queue -join "")
        }

        # verify existance
        $ou_exists = Get-ADOrganizationalUnit -Filter { DistinguishedName -eq $ou_queue }
        
        if (!$ou_exists) {
            try {
                # create ou
                New-ADOrganizationalUnit -Name $ou[$i] -Path $ou_parents -ProtectedFromAccidentalDeletion 0
            }
            catch {
                $message = $_            
                Write-Warning ($message, " [", $ou[$i], "]: " -join "")
                $message | stamp >> script_error.log
                $error_counter++ 
            }
        }
    }

    # reset ou order
    [Array]::Reverse($ou)

    # create a group for each workstation and if necessary add members
    for ($i = 0; $i -lt $Hosts * 10; $i += 10) {
        $client = ([string]($i + 10)).PadLeft(3, '0')

        $common_name = "$prefix`_R$Room`_PC$client$Suffix"
        $scope = if ($common_name.Substring(0, 4) -eq "ACL_") { "DomainLocal" } else { "Global" }

        $member_name = ($members_list | Where-Object {$_.group -eq $prefix}).members
        $member_group = "$member_name`_R$Room`_PC$client$Suffix"

        try {
            # create group
            New-ADGroup -Name $common_name -Path $path.substring(1) -GroupScope $scope -GroupCategory Security -ErrorAction Stop
        }
        catch {
            $message = $_
            if ($message -inotmatch "group already exists") {
                Write-Warning ($message, " [", $common_name, "]: " -join "")
                $message | stamp >> script_error.log
                $error_counter++
            }
        }

        # add members
        $member_is_group = Get-ADGroup -Filter { SamAccountName -eq $member_group }
        try {
            if ($member_name -And $member_is_group) {
                Add-ADGroupMember -Identity $common_name -Members $member_group -ErrorAction Stop
            } elseif ($member_name) {
                Add-ADGroupMember -Identity $common_name -Members $member_name -ErrorAction Stop
            }
        }
        catch {
            $message = $_            
            Write-Warning ($message, " [", $common_name, "]: " -join "")
            $message | stamp >> script_error.log
            $error_counter++
        }
    }
}

Write-Output "`nScript finished with $error_counter errors.`n"

<#

.SYNOPSIS

Creates domain local and global AD groups for preparation of workstations
in educative scenarios. Especially for preparing upcoming domain joins.

.DESCRIPTION

Takes a prefix and creates as many groups for this prefix as there were [Hosts].
The resulting group will be called <Prefix>_R<Room>_PC<Host>_<Suffix>
Prefixes must begin with either "ACL_" or "GG_". Universal groups are not supported.
Group members can be added in the script file.

.PARAMETER Domain

Fully qualified domain name of the domain where the groups are to be created.

.PARAMETER Room

The room number of the physical workstations.

.PARAMETER Hosts

Amount of necessary workstations including teacher and unrelated servers that
should take part in the scenario.

.PARAMETER Suffix

Gets appended to groupname. Can be omitted by passing an empty string.

.PARAMETER Defaults

Uses predefined group names, paths and memberships.
Defaults can be changed in the script file.

.EXAMPLE

New-DomainJoinPrep-Groups -Domain contoso.com -Room 110 -Hosts 20 -Suffix "" -Defaults

.LINK

http://github.com/marianarlt

#>