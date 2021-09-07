#! /usr/bin/python

import os
import re
import sys
import subprocess

from datetime import datetime

TEGOLA_DB_HOST = os.environ.get("TEGOLA_DB_HOST")
TEGOLA_TEGOLA_PASSWORD = os.environ.get("TEGOLA_TEGOLA_PASSWORD")
OSM2PGSQL_STYLE = "/container/config/tegola/osm2pgsql.style"
EXTRACT_BUCKET = "gs://%s" % os.environ.get("EDITOR_DB_DUMP_BUCKET")
UPDATES_FILE = "%s/000/updates.csv" % EXTRACT_BUCKET
UPDATES_TMP = "/tmp/updates.csv"

dryrun = False

def Log(msg):
    print("[%s:%d] %26s: %s" % (
        os.path.basename(__file__),
        os.getpid(),
        datetime.now().strftime("%Y-%m-%d %H:%M:%S:%f"),
        msg)
    )
    sys.stdout.flush()

# Class for maintaining a csv file that contains a log of data files
# that have been loaded.  The log file should contain an initial
# line which is the full path of a *.pdf file, followed by some number
# of additional lines containing *.osc (or *.osc.gz) files.
#
# Example log file contents:
#    /mnt/editor-db/extract/2020-11-13/planet-2020-11-13.pbf
#    /mnt/editor-db/extract/2020-11-14/2020-11-13--2020-11-14.osc.gz
#    /mnt/editor-db/extract/2020-11-15/2020-11-14--2020-11-15.osc.gz
#    /mnt/editor-db/extract/2020-11-16/2020-11-15--2020-11-16.osc.gz
#
# The path names for these files should be such that lexical ordering
# equals chronological ordering.
#
# This class contains methods for:
#   * checking if an osc file (either one that's in the current log file,
#     or a new one) is chronologically after the pbf file
#   * checking if a given osc file is in the current log file or not
#   * adding a new osc file to the log file
class UpdatesFile:
    def __init__(self, path):
        self.path = path
        self.pbf = None
        self.oscs = []
        lines = subprocess.check_output(["gsutil",  "cat", path]).strip().split("\n")
        for line in lines:
            line = line.strip()
            if len(line) == 0:
                continue
            if line.endswith(".pbf"):
                if self.pbf != None:
                    print("Error: updates file '%s' contains multiple pbfs" % path)
                    sys.exit(-1)
                self.pbf = line
                continue
            if not (line.endswith(".osc") or line.endswith(".osc.gz")):
                print("Error: updates file '%s' contains something other than .pbf, .osc, or .osc.gz" % path)
                print(line)
                sys.exit(-1)
            self.oscs.append(line)
    def oscIsAfterPbf(self, osc):
        return osc > self.pbf
    def containsOsc(self, osc):
        return osc in self.oscs
    def appendOsc(self, osc):
        self.oscs.append(osc)
        with open(UPDATES_TMP, "w") as f:
            f.write("%s\n" % self.pbf)
            for osc in self.oscs:
                f.write("%s\n" % osc)
        system("gsutil cp %s %s" % (UPDATES_TMP, UPDATES_FILE))
        #with open(self.path, "a") as f:
        #    f.write("%s\n" % osc)

# Returns the osc file from a directory.
# parent = directory path (e.g. /mnt/editor-db/extract)
# dir = directory name (e.g. "2020-11-05")
# Looks in parent/dir directory for a file whose name matches "--DIR.osc" or  "--DIR.osc.gz", and returns
# the full path of that file if there is exactly one such file, and if there is also a
# file named DONE in the directory.  Otherwise returns None.
# Example:
#   parent="/mnt/editor-db/extract"
#   dir="2020-11-05"
#   Returns "/mnt/editor-db/extract/2020-11-05/2020-11-04--2020-11-05.osc"
#     if such a file exists, and there are no other files in that dir ending
#     with "--2020-11-05.osc", and if "/mnt/editor-db/extract/2020-11-05/DONE" exists.
def GetDoneOscPath(parent, dir):
    oscs = [os.path.join(parent, dir, entry)
            for entry in os.listdir(os.path.join(parent,dir))
            if entry.endswith("--" + dir + ".osc") or entry.endswith("--" + dir + ".osc.gz")]
    if len(oscs) > 1:
        print("Warning: ignoring multple .osc files in directory %s" % os.path.join(parent,dir))
        return None
    done = os.path.exists(os.path.join(parent, dir, "DONE"))
    if done and len(oscs) == 1:
        return oscs[0]
    return None

def GetAllDoneOscs():
    doneOscs = []
    for entry in os.listdir(EXTRACT_DIR):
        if re.match(r'20\d\d-\d\d-\d\d', entry):
            osc = GetDoneOscPath("/mnt/editor-db/extract", entry)
            if osc:
                doneOscs.append(osc)
    doneOscs.sort()
    return doneOscs

def ListBucket(bucket):
    return subprocess.check_output(["gsutil",  "ls", bucket]).strip().split("\n")

def BucketDir(bucket):
  m = re.match(r'^(.*)/[^/]+$', bucket)
  if m:
      return m.group(1)
  return None

def GetAllDoneOscsBucket(bucket):
    listing = subprocess.check_output([
        "gsutil", "ls", "%s/**" % bucket
    ]).strip().split("\n")
    dones = set()
    oscs = set()
    for entry in listing:
        if entry.endswith("DONE"):
            dones.add(BucketDir(entry))
        elif entry.endswith(".osc.gz") or entry.endswith(".osc"):
            oscs.add(entry)
    return [osc for osc in oscs if BucketDir(osc) in dones]

def osm2pgsqlCmd(osc):
    return "gsutil cat %s | gunzip | PGPASSWORD=%s osm2pgsql -a -S %s -C 30000 --slim -d antique -U tegola -H %s -r xml -" % (osc, TEGOLA_TEGOLA_PASSWORD, OSM2PGSQL_STYLE, TEGOLA_DB_HOST)

def system(cmd):
    return os.system(cmd)

def ParseArgs():
    global dryrun
    for i in range(1, len(sys.argv)):
        if sys.argv[i] in ['-d', '--dryrun']:
            dryrun = True
        else:
            print("unrecognized option: %s" % sys.argv[i])
            sys.exit(-1)

def main():
    ParseArgs()
    Log("starting")
    updates = UpdatesFile(UPDATES_FILE)
    doneOscs = GetAllDoneOscsBucket(EXTRACT_BUCKET)
    for osc in sorted(doneOscs):
        if updates.oscIsAfterPbf(osc) and not updates.containsOsc(osc):
            Log("appending %s to updates.csv" % osc)
            if not dryrun:
                updates.appendOsc(osc)
            cmd = osm2pgsqlCmd(osc)
            Log("executing: %s" % cmd)
            if not dryrun:
                system(cmd)
    Log("done")

if __name__ == "__main__":
    main()
