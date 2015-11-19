#include <stdio.h>
#include <HsFFI.h>

HsInt
hs_read_bytes(const HsInt buf, char* fp, char* buffer) {
    FILE* pFile;
    long bufSize = (long)buf;
    pFile = fopen(fp, "rb");
    fread(buffer,1,bufSize,pFile);
    fclose(pFile);
    return 0;
}

HsInt
hs_read_many_bytes(const HsInt buf, const HsInt ct, char** fps, char** buffers) {
    FILE* pFile;
    long bufSize = (long)buf;
    for (int i = 0; i < ct; ++i) {
        char* fp = fps[i];
        char* buffer = buffers[i];
        pFile = fopen(fp, "rb");
        fread(buffer,1,bufSize,pFile);
        fclose(pFile);
    }
    return 0;
}

