#
#

# Copyright (C) 2010, 2011 Google Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
# 1. Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
# IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


"""Module containing backported language/library functionality.

"""

import itertools
import operator

try:
  # pylint: disable=F0401
  import functools
except ImportError:
  functools = None

try:
  # pylint: disable=F0401
  import roman
except ImportError:
  roman = None


# compat.md5_hash and compat.sha1_hash can be called to generate and md5 and a
# sha1 hashing modules, under python 2.4, 2.5 and 2.6, even though some changes
# went on. compat.sha1 is python-version specific and is used for python
# modules (hmac, for example) which have changed their behavior as well from
# one version to the other.
try:
  # Yes, these don't always exist, that's why we're testing
  # Yes, we're not using the imports in this module.
  from hashlib import md5 as md5_hash # pylint: disable=W0611,E0611,F0401
  from hashlib import sha1 as sha1_hash # pylint: disable=W0611,E0611,F0401
  # this additional version is needed for compatibility with the hmac module
  sha1 = sha1_hash
except ImportError:
  from md5 import new as md5_hash
  import sha
  sha1 = sha
  sha1_hash = sha.new


def _all(seq):
  """Returns True if all elements in the iterable are True.

  """
  for _ in itertools.ifilterfalse(bool, seq):
    return False
  return True


def _any(seq):
  """Returns True if any element of the iterable are True.

  """
  for _ in itertools.ifilter(bool, seq):
    return True
  return False


try:
  # pylint: disable=E0601
  # pylint: disable=W0622
  all = all
except NameError:
  all = _all

try:
  # pylint: disable=E0601
  # pylint: disable=W0622
  any = any
except NameError:
  any = _any


def partition(seq, pred=bool): # pylint: disable=W0622
  """Partition a list in two, based on the given predicate.

  """
  return (list(itertools.ifilter(pred, seq)),
          list(itertools.ifilterfalse(pred, seq)))


# Even though we're using Python's built-in "partial" function if available,
# this one is always defined for testing.
def _partial(func, *args, **keywords): # pylint: disable=W0622
  """Decorator with partial application of arguments and keywords.

  This function was copied from Python's documentation.

  """
  def newfunc(*fargs, **fkeywords):
    newkeywords = keywords.copy()
    newkeywords.update(fkeywords)
    return func(*(args + fargs), **newkeywords) # pylint: disable=W0142

  newfunc.func = func
  newfunc.args = args
  newfunc.keywords = keywords
  return newfunc


if functools is None:
  partial = _partial
else:
  partial = functools.partial


def TryToRoman(val, convert=True):
  """Try to convert a value to roman numerals

  If the roman module could be loaded convert the given value to a roman
  numeral. Gracefully fail back to leaving the value untouched.

  @type val: integer
  @param val: value to convert
  @type convert: boolean
  @param convert: if False, don't try conversion at all
  @rtype: string or typeof(val)
  @return: roman numeral for val, or val if conversion didn't succeed

  """
  if roman is not None and convert:
    try:
      return roman.toRoman(val)
    except roman.RomanError:
      return val
  else:
    return val


def UniqueFrozenset(seq):
  """Makes C{frozenset} from sequence after checking for duplicate elements.

  @raise ValueError: When there are duplicate elements

  """
  if isinstance(seq, (list, tuple)):
    items = seq
  else:
    items = list(seq)

  result = frozenset(items)

  if len(items) != len(result):
    raise ValueError("Duplicate values found")

  return result


#: returns the first element of a list-like value
fst = operator.itemgetter(0)

#: returns the second element of a list-like value
snd = operator.itemgetter(1)
