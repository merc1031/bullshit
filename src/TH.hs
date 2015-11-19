{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module TH where

import qualified Language.C.Inline as C

C.include "<stdio.h>"

readFile path buffer = [C.block| void {
      f = fopen($path, "r");
      fread($buffer,1,$bufSize, f);
      fclose(f);
    } |]

