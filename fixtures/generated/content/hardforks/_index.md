+++
title = "Hardforks"
template = "hardforks.html"

[[extra.network_upgrades]]
slug = "pectra"
display_name = "Pectra"
meta_eip = 7201
meta = { local_route = "/7201/", public_url = "https://eips.ethereum.org/EIPS/eip-7201" }
meta_status = "Final"

[[extra.network_upgrades.stages]]
key = "included"
label = "Included"

[[extra.network_upgrades.stages.rows]]
number = 214
title = "New opcode STATICCALL"
status = "Final"
type = "Standards Track"
destination = { local_route = "/214/", public_url = "https://eips.ethereum.org/EIPS/eip-214" }
category = "Core"
subgroup = "Core EIPs"

[[extra.network_upgrades.stages.rows]]
number = 165
title = "Standard Interface Detection"
status = "Final"
type = "Standards Track"
destination = { local_route = "/165/", public_url = "https://ercs.ethereum.org/ERCS/erc-165" }
category = "ERC"
subgroup = "Other EIPs"

[[extra.network_upgrades]]
slug = "glamsterdam"
display_name = "Glamsterdam"
meta_eip = 7773
meta = { public_url = "https://eips.ethereum.org/EIPS/eip-7773" }
meta_status = "Draft"

[[extra.network_upgrades.stages]]
key = "scheduled"
label = "Scheduled for Inclusion"

[[extra.network_upgrades.stages.rows]]
number = 165
title = "Standard Interface Detection"
status = "Final"
type = "Standards Track"
destination = { public_url = "https://ercs.ethereum.org/ERCS/erc-165" }
category = "ERC"

[[extra.network_upgrades.stages.rows]]
number = 7773
title = "Glamsterdam Meta EIP"
status = "Draft"
type = "Meta"
destination = { public_url = "https://eips.ethereum.org/EIPS/eip-7773" }

[[extra.network_upgrades.stages]]
key = "considered"
label = "Considered for Inclusion"
rows = []

[[extra.network_upgrades]]
slug = "empty-demo"
display_name = "Empty Demo"
meta_eip = 7201
meta = { local_route = "/7201/", public_url = "https://eips.ethereum.org/EIPS/eip-7201" }
meta_status = "Draft"

[[extra.network_upgrades.stages]]
key = "included"
label = "Included"
rows = []
+++
