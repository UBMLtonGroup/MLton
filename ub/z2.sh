

for i in 0 1 2 ; do 
    gcc -w -o test2.${i}.o -c test2.${i}.i
done

      gcc -g -o test2 test2.?.o \
          -L/home/jcmurphy/MLton/build/lib/targets/self -lmlton -lgdtoa -lm \
          -lgmp -m64 -lpthread -lrt
