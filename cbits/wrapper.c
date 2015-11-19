#include <stdio.h>
#include <HsFFI.h>

HsInt
hs_read_bytes(const HsInt i, char* fp) {
    FILE* pFile;
    char* buffer;
    long bufSize = (long)i;
    pFile = fopen(fp, "r");
    buffer = (char*) malloc (sizeof(char)*i);
    fread(buffer,1,i,pFile);
    fclose(pFile);
    free (buffer);
    return 0;
}

