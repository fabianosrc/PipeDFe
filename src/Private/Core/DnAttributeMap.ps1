<#
.SYNOPSIS
Defines the DN attribute display name map used by ConvertFrom-CertificateSubject.

.DESCRIPTION
Maps uppercase DN attribute abbreviations to their Portuguese human-readable
labels. Initialized once at module load time and treated as read-only.
#>
$Script:DnAttributeMap = @{
    CN           = 'Nome Comum'
    OU           = 'Unidade Organizacional'
    O            = 'Organizacao'
    L            = 'Municipio'
    S            = 'Estado'
    ST           = 'Estado'
    C            = 'Pais'
    DC           = 'Componente de Dominio'
    UID          = 'Identificador de Usuario'
    EMAIL        = 'E-mail'
    EMAILADDRESS = 'E-mail'
    SERIALNUMBER = 'Numero de Serie'
    STREET       = 'Logradouro'
    T            = 'Cargo'
    G            = 'Nome'
    I            = 'Iniciais'
}
