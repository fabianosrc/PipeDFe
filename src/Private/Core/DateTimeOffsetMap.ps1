<#
.SYNOPSIS
Defines the supported date/time parsing formats for ConvertTo-DateTimeOffset.

.DESCRIPTION
Contains the ordered set of exact date/time formats accepted by
ConvertTo-DateTimeOffset.

Each entry defines:
- Format: The exact .NET date/time format pattern.
- Culture: The culture used to interpret the format.
- Styles: The DateTimeStyles applied during parsing.

Formats without an explicit UTC offset use AssumeLocal and are therefore
interpreted using the local system time zone.

Formats with an explicit UTC offset preserve that offset during parsing and
are subsequently normalized to UTC by ConvertTo-DateTimeOffset.

The collection is initialized when the module is loaded and is intended to
be treated as internal, read-only configuration.

.NOTES
This variable is not part of the module public API.
#>

$invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$brazilianCulture = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')

$Script:DateTimeOffsetFormats = @(
    # ISO 8601 with explicit UTC offset.
    @{
        Format  = 'yyyy-MM-ddTHH:mm:ss.fffffffzzz'
        Culture = $invariantCulture
        Styles  = [System.Globalization.DateTimeStyles]::None
    }
    @{
        Format  = 'yyyy-MM-ddTHH:mm:sszzz'
        Culture = $invariantCulture
        Styles  = [System.Globalization.DateTimeStyles]::None
    }

    # ISO 8601 without explicit offset. Local system offset is assumed.
    @{
        Format  = 'yyyy-MM-ddTHH:mm:ss.fff'
        Culture = $invariantCulture
        Styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
    }
    @{
        Format  = 'yyyy-MM-ddTHH:mm:ss'
        Culture = $invariantCulture
        Styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
    }
    @{
        Format  = 'yyyy-MM-dd HH:mm:ss'
        Culture = $invariantCulture
        Styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
    }
    @{
        Format  = 'yyyy-MM-dd'
        Culture = $invariantCulture
        Styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
    }

    # Brazilian date formats without explicit offset. Local system offset
    # is assumed.
    @{
        Format  = 'dd/MM/yyyy HH:mm:ss'
        Culture = $brazilianCulture
        Styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
    }
    @{
        Format  = 'dd/MM/yyyy'
        Culture = $brazilianCulture
        Styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
    }
    @{
        Format  = 'dd-MM-yyyy HH:mm:ss'
        Culture = $brazilianCulture
        Styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
    }
    @{
        Format  = 'dd-MM-yyyy'
        Culture = $brazilianCulture
        Styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
    }
)
