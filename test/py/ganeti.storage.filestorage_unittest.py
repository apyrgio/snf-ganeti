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


"""Script for unittesting the ganeti.storage.filestorage module"""

import os
import shutil
import tempfile
import unittest

from ganeti import errors
from ganeti.storage import filestorage
from ganeti import utils

import testutils


class TestFileStorageSpaceInfo(unittest.TestCase):

  def testSpaceInfoPathInvalid(self):
    """Tests that an error is raised when the given path is not existing.

    """
    self.assertRaises(errors.CommandError, filestorage.GetFileStorageSpaceInfo,
                      "/path/does/not/exist/")

  def testSpaceInfoPathValid(self):
    """Smoke test run on a directory that exists for sure.

    """
    filestorage.GetFileStorageSpaceInfo("/")


class TestCheckFileStoragePath(unittest.TestCase):
  def _WriteAllowedFile(self, allowed_paths_filename, allowed_paths):
    allowed_paths_file = open(allowed_paths_filename, 'w')
    allowed_paths_file.write('\n'.join(allowed_paths))
    allowed_paths_file.close()

  def setUp(self):
    self.tmpdir = tempfile.mkdtemp()
    self.allowed_paths = [os.path.join(self.tmpdir, "allowed")]
    for path in self.allowed_paths:
      os.mkdir(path)
    self.allowed_paths_filename = os.path.join(self.tmpdir, "allowed-path-file")
    self._WriteAllowedFile(self.allowed_paths_filename, self.allowed_paths)

  def tearDown(self):
    shutil.rmtree(self.tmpdir)

  def testCheckFileStoragePathExistance(self):
    filestorage._CheckFileStoragePathExistance(self.tmpdir)

  def testCheckFileStoragePathExistanceFail(self):
    path = os.path.join(self.tmpdir, "does/not/exist")
    self.assertRaises(errors.FileStoragePathError,
        filestorage._CheckFileStoragePathExistance, path)

  # def testCheckFileStoragePathNotWritable(self):
  #   path = os.path.join(self.tmpdir, "isnotwritable/")
  #   os.mkdir(path)
  #   os.chmod(path, 0)
  #   self.assertRaises(errors.FileStoragePathError,
  #       filestorage._CheckFileStoragePathExistance, path)
  #   os.chmod(path, 777)

  def testCheckFileStoragePath(self):
    path = os.path.join(self.allowed_paths[0], "allowedsubdir")
    os.mkdir(path)
    result = filestorage.CheckFileStoragePath(
        path, _allowed_paths_file=self.allowed_paths_filename)
    self.assertEqual(None, result)

  def testCheckFileStoragePathNotAllowed(self):
    path = os.path.join(self.tmpdir, "notallowed")
    result = filestorage.CheckFileStoragePath(
        path, _allowed_paths_file=self.allowed_paths_filename)
    self.assertTrue("not acceptable" in result)


class TestLoadAllowedFileStoragePaths(testutils.GanetiTestCase):
  def testDevNull(self):
    self.assertEqual(filestorage._LoadAllowedFileStoragePaths("/dev/null"), [])

  def testNonExistantFile(self):
    filename = "/tmp/this/file/does/not/exist"
    assert not os.path.exists(filename)
    self.assertEqual(filestorage._LoadAllowedFileStoragePaths(filename), [])

  def test(self):
    tmpfile = self._CreateTempFile()

    utils.WriteFile(tmpfile, data="""
      # This is a test file
      /tmp
      /srv/storage
      relative/path
      """)

    self.assertEqual(filestorage._LoadAllowedFileStoragePaths(tmpfile), [
      "/tmp",
      "/srv/storage",
      "relative/path",
      ])


class TestComputeWrongFileStoragePathsInternal(unittest.TestCase):
  def testPaths(self):
    paths = filestorage._GetForbiddenFileStoragePaths()

    for path in ["/bin", "/usr/local/sbin", "/lib64", "/etc", "/sys"]:
      self.assertTrue(path in paths)

    self.assertEqual(set(map(os.path.normpath, paths)), paths)

  def test(self):
    vfsp = filestorage._ComputeWrongFileStoragePaths
    self.assertEqual(vfsp([]), [])
    self.assertEqual(vfsp(["/tmp"]), [])
    self.assertEqual(vfsp(["/bin/ls"]), ["/bin/ls"])
    self.assertEqual(vfsp(["/bin"]), ["/bin"])
    self.assertEqual(vfsp(["/usr/sbin/vim", "/srv/file-storage"]),
                     ["/usr/sbin/vim"])


class TestComputeWrongFileStoragePaths(testutils.GanetiTestCase):
  def test(self):
    tmpfile = self._CreateTempFile()

    utils.WriteFile(tmpfile, data="""
      /tmp
      x/y///z/relative
      # This is a test file
      /srv/storage
      /bin
      /usr/local/lib32/
      relative/path
      """)

    self.assertEqual(
        filestorage.ComputeWrongFileStoragePaths(_filename=tmpfile),
        ["/bin",
         "/usr/local/lib32",
         "relative/path",
         "x/y/z/relative",
        ])


class TestCheckFileStoragePathInternal(unittest.TestCase):
  def testNonAbsolute(self):
    for i in ["", "tmp", "foo/bar/baz"]:
      self.assertRaises(errors.FileStoragePathError,
                        filestorage._CheckFileStoragePath, i, ["/tmp"])

    self.assertRaises(errors.FileStoragePathError,
                      filestorage._CheckFileStoragePath, "/tmp", ["tmp", "xyz"])

  def testNoAllowed(self):
    self.assertRaises(errors.FileStoragePathError,
                      filestorage._CheckFileStoragePath, "/tmp", [])

  def testNoAdditionalPathComponent(self):
    self.assertRaises(errors.FileStoragePathError,
                      filestorage._CheckFileStoragePath, "/tmp/foo",
                      ["/tmp/foo"])

  def testAllowed(self):
    filestorage._CheckFileStoragePath("/tmp/foo/a", ["/tmp/foo"])
    filestorage._CheckFileStoragePath("/tmp/foo/a/x", ["/tmp/foo"])


class TestCheckFileStoragePathExistance(testutils.GanetiTestCase):
  def testNonExistantFile(self):
    filename = "/tmp/this/file/does/not/exist"
    assert not os.path.exists(filename)
    self.assertRaises(errors.FileStoragePathError,
                      filestorage.CheckFileStoragePathAcceptance, "/bin/",
                      _filename=filename)
    self.assertRaises(errors.FileStoragePathError,
                      filestorage.CheckFileStoragePathAcceptance,
                      "/srv/file-storage", _filename=filename)

  def testAllowedPath(self):
    tmpfile = self._CreateTempFile()

    utils.WriteFile(tmpfile, data="""
      /srv/storage
      """)

    filestorage.CheckFileStoragePathAcceptance(
        "/srv/storage/inst1", _filename=tmpfile)

    # No additional path component
    self.assertRaises(errors.FileStoragePathError,
                      filestorage.CheckFileStoragePathAcceptance,
                      "/srv/storage", _filename=tmpfile)

    # Forbidden path
    self.assertRaises(errors.FileStoragePathError,
                      filestorage.CheckFileStoragePathAcceptance,
                      "/usr/lib64/xyz", _filename=tmpfile)


if __name__ == "__main__":
  testutils.GanetiTestProgram()
