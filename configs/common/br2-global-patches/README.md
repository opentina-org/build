# BR2_GLOBAL_PATCH_DIR

Hashes for the OP-TEE sources pinned to 4.6.0. `BR2_DOWNLOAD_FORCE_CHECK_HASHES=y`
clears Buildroot's `BR_NO_CHECK_HASH_FOR` exemption list (`package/pkg-download.mk`),
so every custom tarball needs a hash here; the in-tree `package/*/*.hash` files only
carry the version Buildroot currently ships.
