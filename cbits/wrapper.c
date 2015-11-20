#include <stdio.h>
#include <HsFFI.h>

HsInt
hs_read_bytes(const HsInt i, char* fp, char* buffer) {
    FILE* pFile;
    long bufSize = (long)i;
    pFile = fopen(fp, "r");
    fread(buffer,1,i,pFile);
    fclose(pFile);
    return 0;
}

