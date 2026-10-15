-- SLRR Drivers: load the extensions and keep them alive across level loads.
extensions.load('slrrDrivers')
setExtensionUnloadMode('slrrDrivers', 'manual')
extensions.load('slrrPedestrians')
setExtensionUnloadMode('slrrPedestrians', 'manual')
extensions.load('slrrDriverMount')   -- before any vehicle spawns: its jbeam hook adds the driver to cars (flags, off by default)
setExtensionUnloadMode('slrrDriverMount', 'manual')
