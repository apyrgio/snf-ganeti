#!/usr/bin/python
#

# Copyright (C) 2013 Google Inc.
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


"""Script for unittesting the ganeti.utils.storage module"""

import mock

import unittest

from ganeti import constants
from ganeti.utils import storage

import testutils


class TestGetStorageUnitForDiskTemplate(unittest.TestCase):

  def setUp(self):
    self._default_vg_name = "some_vg_name"
    self._cluster = mock.Mock()
    self._cluster.file_storage_dir = "my/file/storage/dir"
    self._cluster.shared_file_storage_dir = "my/shared/file/storage/dir"
    self._cfg = mock.Mock()
    self._cfg.GetVGName = mock.Mock(return_value=self._default_vg_name)
    self._cfg.GetClusterInfo = mock.Mock(return_value=self._cluster)

  def testGetDefaultStorageUnitForDiskTemplateLvm(self):
    for disk_template in [constants.DT_DRBD8, constants.DT_PLAIN]:
      (storage_type, storage_key) = \
          storage._GetDefaultStorageUnitForDiskTemplate(self._cfg,
                                                        disk_template)
      self.assertEqual(storage_type, constants.ST_LVM_VG)
      self.assertEqual(storage_key, self._default_vg_name)

  def testGetDefaultStorageUnitForDiskTemplateFile(self):
    (storage_type, storage_key) = \
        storage._GetDefaultStorageUnitForDiskTemplate(self._cfg,
                                                      constants.DT_FILE)
    self.assertEqual(storage_type, constants.ST_FILE)
    self.assertEqual(storage_key, self._cluster.file_storage_dir)

  def testGetDefaultStorageUnitForDiskTemplateSharedFile(self):
    (storage_type, storage_key) = \
        storage._GetDefaultStorageUnitForDiskTemplate(self._cfg,
                                                      constants.DT_SHARED_FILE)
    self.assertEqual(storage_type, constants.ST_FILE)
    self.assertEqual(storage_key, self._cluster.shared_file_storage_dir)

  def testGetDefaultStorageUnitForDiskTemplateDiskless(self):
    (storage_type, storage_key) = \
        storage._GetDefaultStorageUnitForDiskTemplate(self._cfg,
                                                      constants.DT_DISKLESS)
    self.assertEqual(storage_type, constants.ST_DISKLESS)
    self.assertEqual(storage_key, None)


class TestGetStorageUnits(unittest.TestCase):

  def setUp(self):
    storage._GetDefaultStorageUnitForDiskTemplate = \
        mock.Mock(return_value=("foo", "bar"))
    self._cfg = mock.Mock()

  def testGetStorageUnits(self):
    disk_templates = [constants.DT_FILE, constants.DT_SHARED_FILE]
    storage_units = storage.GetStorageUnits(self._cfg, disk_templates)
    self.assertEqual(len(storage_units), len(disk_templates))

  def testGetStorageUnitsLvm(self):
    disk_templates = [constants.DT_PLAIN, constants.DT_DRBD8]
    storage_units = storage.GetStorageUnits(self._cfg, disk_templates)
    self.assertEqual(len(storage_units), len(disk_templates))


class TestLookupSpaceInfoByStorageType(unittest.TestCase):

  def setUp(self):
    self._space_info = [
        {"type": st, "name": st + "_key", "storage_size": 0, "storage_free": 0}
        for st in constants.STORAGE_TYPES]

  def testValidLookup(self):
    query_type = constants.ST_LVM_PV
    result = storage.LookupSpaceInfoByStorageType(self._space_info, query_type)
    self.assertEqual(query_type, result["type"])

  def testNotInList(self):
    result = storage.LookupSpaceInfoByStorageType(self._space_info,
                                                  "non_existing_type")
    self.assertEqual(None, result)


if __name__ == "__main__":
  testutils.GanetiTestProgram()
