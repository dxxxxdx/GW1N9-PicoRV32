//
// Created by dxxdx on 2026/9/24.
//

#include "../hostutil/include/UART.h"

int main()
{

    unsigned char msg[6] = "000\r\n";

    for (int i = 0; i < 10 ; i++)
    {
        for (int j = 0; j < 10; j++)
        {
            for (int k = 0; k < 10; k++)
            {
                UART_String(msg,5);
                msg[2] += 1;
            }
            msg[2] = '0';
            msg[1] += 1;
        }
        msg[1] = '0';
        msg[0] += 1;
    }

    while (1);


};



