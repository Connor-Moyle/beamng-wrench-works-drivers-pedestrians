-- SLRR Drivers: load the extensions and keep them alive across level loads.
setExtensionUnloadMode('slrrDrivers', 'manual')
extensions.load('slrrDrivers')
setExtensionUnloadMode('slrrPedestrians', 'manual')
extensions.load('slrrPedestrians')
setExtensionUnloadMode('slrrDriverMount', 'manual')
extensions.load('slrrDriverMount')   -- before any vehicle spawns: its jbeam hook adds the driver to cars (flags, off by default)
