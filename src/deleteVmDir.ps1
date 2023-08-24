# function checks if directory exists. If it does and contains only files matching FileMask, dir is deleted.
# function returns true if cleaning is successful (in the end dir is no more), false 
#   otherwise (dir ccontains something else and cant be deleted)
function ListAndDeleteDirectory {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$FileMask
    )

    # Check if the directory exists
    if (-not (Test-Path -Path $Path -PathType Container)) {
        Write-Debug "Directory $Path does not exist."
        return $true
    }

    # Get the contents of the directory
    $contents = Get-ChildItem -Path $Path
    $allCount = ($contents).Count
    Write-Debug "Directory $Path contains total $allCount of following $contents files."

    # Directory is empty or doesn't contain the file
    if ($allCount -eq 0) {
        Write-Debug "Directory $Path is empty. Deleting."
        Remove-Item -Path $Path -Recurse -Force
        return $true
    }
    
    # Check how many files matching mask
    $fileCount = ($contents | Where-Object { $_.Name -match $FileMask -and $_.PSIsContainer -eq $false }).Count
    Write-Debug "Directory $Path contains $fileCount files matching mask: $FileMask"
    if ($fileCount -eq $allCount) {
        # All matching mask - delete the directory and the files
        Remove-Item -Path $Path -Recurse -Force
        Write-Debug "Directory $Path and file $FileMask deleted."
        return $true
    }
    # Error: Directory contains other files
    Write-Debug "Directory $Path contains other files and/or directories."
    return $false
}
