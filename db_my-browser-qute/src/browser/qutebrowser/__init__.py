# SPDX-FileCopyrightText: Freya Bruhin (The Compiler) <mail@qutebrowser.org>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""my-browser-qute - a keyboard-driven browser with a native bookmark/plugin bar."""

import os.path
import datetime

_year = datetime.date.today().year

__author__ = "Freya Bruhin"
__copyright__ = "Copyright 2013-{} Freya Bruhin (The Compiler)".format(_year)
__license__ = "GPL-3.0-or-later"
__maintainer__ = __author__
__email__ = "mail@qutebrowser.org"
__version__ = "3.7.0"
__version_info__ = tuple(int(part) for part in __version__.split('.'))
__description__ = "my-browser-qute - a keyboard-driven browser with a native bookmark/plugin bar."

basedir = os.path.dirname(os.path.realpath(__file__))
