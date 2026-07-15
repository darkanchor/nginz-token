# Third-party notices

The repository-level [Business Source License 1.1](LICENSE) does not replace
the license terms attached to third-party components. Those components include:

| Component | Location | Revision | License |
| --- | --- | --- | --- |
| cJSON | `src/c/cJSON.c`, `src/c/cJSON.h` | vendored source | MIT; the copyright and license notice is embedded in each file |
| libinjection | `src/c/libinjection/` | vendored source | BSD 3-Clause; see [`COPYING`](src/c/libinjection/COPYING) |
| nginx | `submodules/nginx/` | `47c3628d23efaa1bfb1a32afbe9e3d013f860c2c` | nginx license; see [`LICENSE`](submodules/nginx/LICENSE) |
| njs | `submodules/njs/` | `ad60b62c3b4ca6339ca19c19ceed8c942dbe575d` | BSD 2-Clause; see [`LICENSE`](submodules/njs/LICENSE) |
| QuickJS | `submodules/quickjs/` | `3d5e064e9dd67c70f7962836505a7fa067bf0a4e` | MIT; see [`LICENSE`](submodules/quickjs/LICENSE) |

The submodule source is not stored in this repository's Git history. Cloning
with `--recurse-submodules`, or running `git submodule update --init
--recursive`, checks out the revisions recorded above. Review the license file
inside each checked-out submodule before redistributing it.
