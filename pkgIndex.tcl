# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Register the package and load its dependencies.
package ifneeded web-forum 1.0.0 [list source [file join $dir library web-forum.tcl]]

# Locate the manifest without loading application services.
package ifneeded web-forum::manifest 1.0.0 [list apply {{dir} {
    package require web-core
    ::web::core::register web-forum $dir
    package provide web-forum::manifest 1.0.0
}} $dir]
