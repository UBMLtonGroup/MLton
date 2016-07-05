
      gcc -E -g -std=gnu99 -c -I/home/jcmurphy/MLton/build/lib/targets/self/include \
          -I/home/jcmurphy/MLton/build/lib/include -O1 -fno-common \
          -D_GNU_SOURCE -D__USE_GNU -fno-strict-aliasing -fomit-frame-pointer \
          -w -m64 -o test2.2.i test2.2.c
      gcc -E -g -std=gnu99 -c -I/home/jcmurphy/MLton/build/lib/targets/self/include \
          -I/home/jcmurphy/MLton/build/lib/include -O1 -fno-common \
          -D_GNU_SOURCE -D__USE_GNU -fno-strict-aliasing -fomit-frame-pointer \
          -w -m64 -o test2.1.i test2.1.c
      gcc -E -g -std=gnu99 -c -I/home/jcmurphy/MLton/build/lib/targets/self/include \
          -I/home/jcmurphy/MLton/build/lib/include -O1 -fno-common \
          -D_GNU_SOURCE -D__USE_GNU -fno-strict-aliasing -fomit-frame-pointer \
          -w -m64 -o test2.0.i test2.0.c

for i in 0 1 2 ; do 
    gcc -o test2.${i}.o -c test2.${i}.i
done

      gcc -g -o test2 test2.?.o \
          -L/home/jcmurphy/MLton/build/lib/targets/self -lmlton -lgdtoa -lm \
          -lgmp -m64 -lpthread -lrt
