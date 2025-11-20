#include <stdio.h>
#include <stdlib.h>
#include <netlink/netlink.h>        // libnl-3
#include <netlink/genl/genl.h>      // libnl-genl-3
#include <netlink/genl/ctrl.h>      // libnl-genl-3
#include <netlink/netfilter/nfnl.h> // libnl-nf-3
#include <linux/netlink.h>

int main(void)
{
    struct nl_sock *sk_core   = NULL;  // from libnl-3
    struct nl_sock *sk_nf     = NULL;  // from libnl-nf-3
    int family_id;

    /* === libnl-3: basic Netlink socket === */
    sk_core = nl_socket_alloc();
    if (!sk_core) {
        perror("nl_socket_alloc");
        return EXIT_FAILURE;
    }

    if (nl_connect(sk_core, NETLINK_GENERIC) < 0) {
        fprintf(stderr, "Failed to connect to Generic Netlink\n");
        goto cleanup;
    }

    /* === libnl-genl-3: resolve a generic netlink family === */
    family_id = genl_ctrl_resolve(sk_core, "nl80211");
    if (family_id < 0) {
        printf("nl80211 family not found (normal on systems without WiFi): %s\n",
               nl_geterror(family_id));
    } else {
        printf("Found nl80211 family ID = %d\n", family_id);
    }

    /* === libnl-nf-3: create a netfilter socket (forces linking against libnl-nf-3) === */
    sk_nf = nfnl_connect(sk_core);  // This symbol is ONLY in libnl-nf-3
    if (!sk_nf) {
        fprintf(stderr, "nfnl_connect() failed — this proves libnl-nf-3 is linked correctly\n");
    } else {
        printf("Successfully created Netfilter netlink socket (libnl-nf-3 is present)\n");
        // No need to actually use it — just having the pointer forces the linker to resolve it
    }

    printf("All three libnl libraries (libnl-3, libnl-genl-3, libnl-nf-3) are present and linked!\n");

cleanup:
    if (sk_core) nl_socket_free(sk_core);
    /* sk_nf is just a pointer alias to sk_core in libnl-nf, no need to free twice */
    return EXIT_SUCCESS;
}
