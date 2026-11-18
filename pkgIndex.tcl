# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Register the package and load its dependencies.
package ifneeded web-forum 0.3.4 [list source [file join $dir library web-forum.tcl]]

package ifneeded web-forum::routes 1.0 [list source [file join $dir library routes.tcl]]
