/* SPDX-License-Identifier: GPL-2.0-only */
#include <arpa/inet.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    unsigned char bytes[sizeof(struct in6_addr)];
    char text[INET6_ADDRSTRLEN];
    int family;

    if (argc != 2)
        return 2;
    if (inet_pton(AF_INET, argv[1], bytes) == 1)
        family = AF_INET;
    else if (inet_pton(AF_INET6, argv[1], bytes) == 1)
        family = AF_INET6;
    else
        return 1;
    return inet_ntop(family, bytes, text, sizeof(text)) && puts(text) >= 0 ? 0 : 1;
}
