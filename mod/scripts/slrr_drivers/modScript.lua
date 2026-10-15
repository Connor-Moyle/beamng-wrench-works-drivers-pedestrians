-- SLRR Drivers: load the extensions and keep them alive across level loads.
extensions.load('slrrDrivers')
setExtensionUnloadMode('slrrDrivers', 'manual')
extensions.load('slrrPedestrians')
setExtensionUnloadMode('slrrPedestrians', 'manual')
