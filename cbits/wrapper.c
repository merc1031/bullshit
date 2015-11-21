#include <stdio.h>
#include <HsFFI.h>

HsInt
hs_read_bytes(const HsInt bs, char* fp, char* buffer) {
    FILE* pFile;
    long bufSize = (long)bs;
    pFile = fopen(fp, "r");
    fread(buffer,1,bufSize,pFile);
    fclose(pFile);
    return 0;
}

HsInt
hs_read_bytes_a(const HsInt bs, const HsInt ct, char** fps, char* buffer) {
    FILE* pFile;
    long bufSize = (long)bs;
    for(int i = 0; i < ct; ++i) {
        char* fp = fps[i];
        pFile = fopen(fp, "r");
        fread(buffer,1,bufSize,pFile);
        fclose(pFile);
    }
    return 0;
}

