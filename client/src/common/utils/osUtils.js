export const OS_OPTIONS = [
    { value: 'Windows', label: 'Windows' },
    { value: 'Ubuntu', label: 'Ubuntu' },
    { value: 'Debian', label: 'Debian' },
    { value: 'Alpine Linux', label: 'Alpine Linux' },
    { value: 'Fedora', label: 'Fedora' },
    { value: 'CentOS', label: 'CentOS' },
    { value: 'Red Hat', label: 'Red Hat' },
    { value: 'Rocky Linux', label: 'Rocky Linux' },
    { value: 'AlmaLinux', label: 'AlmaLinux' },
    { value: 'openSUSE', label: 'openSUSE' },
    { value: 'Arch Linux', label: 'Arch Linux' },
    { value: 'Manjaro', label: 'Manjaro' },
    { value: 'Gentoo', label: 'Gentoo' },
    { value: 'NixOS', label: 'NixOS' },
    { value: 'Proxmox VE', label: 'Proxmox VE' },
];

export const parseOsFilter = (osFilter) => {
    if (!osFilter) return [];
    if (Array.isArray(osFilter)) return osFilter;
    if (typeof osFilter === 'string') {
        try { return JSON.parse(osFilter); } catch { return []; }
    }
    return [];
};

export const normalizeOsName = (osName) => {
    if (!osName) return null;
    const lower = osName.toLowerCase();
    const mappings = [
        ['windows', 'Windows'], ['microsoft windows', 'Windows'],
        ['ubuntu', 'Ubuntu'], ['debian', 'Debian'], ['alpine', 'Alpine Linux'],
        ['fedora', 'Fedora'], ['centos', 'CentOS'], ['red hat', 'Red Hat'], ['rhel', 'Red Hat'],
        ['rocky', 'Rocky Linux'], ['alma', 'AlmaLinux'], ['opensuse', 'openSUSE'], ['suse', 'openSUSE'],
        ['arch', 'Arch Linux'], ['manjaro', 'Manjaro'], ['gentoo', 'Gentoo'],
        ['nixos', 'NixOS'], ['proxmox', 'Proxmox VE'],
    ];
    for (const [key, value] of mappings) {
        if (lower.includes(key)) return value;
    }
    return osName;
};

export const normalizeScriptOsFilter = (osFilter) => {
    const filter = parseOsFilter(osFilter).map(normalizeOsName);
    return filter.includes('Windows') ? ['Windows'] : filter;
};

export const normalizeOsNameFromIcon = (icon) => {
    if (!icon) return null;
    const normalized = normalizeOsName(icon);
    return normalized === icon ? null : normalized;
};

export const matchesOsFilter = (osFilter, serverOsName, isPveEntry) => {
    const filter = parseOsFilter(osFilter).map(normalizeOsName);
    const hasPveFilter = filter.includes('Proxmox VE');
    const isOnlyPve = filter.length === 1 && hasPveFilter;
    
    if (isPveEntry) {
        if (filter.length === 0) return true;
        return hasPveFilter;
    } else {
        if (filter.length === 0) return true;
        if (isOnlyPve) return false;
        if (!serverOsName) return false;
        return filter.includes(serverOsName);
    }
};
