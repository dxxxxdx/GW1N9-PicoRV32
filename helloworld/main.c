//
// Created by dxxdx on 2026/9/24.
//

#include "../hostutil/include/UART.h"
#include "../hostutil/include/IRQ.h"



int main()
{


    IRQ_Init();
    IRQ_Enable(IRQ_CH0);


    unsigned char msg[6] = "000\r\n";


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


    while (1)
    {
        for (volatile int j = 0; j < 10000; j++);
        UART_String(msg,5);
    }

};

const uint8_t ch0msg[] = "CH0 trigged!";
void IRQ_Ch0_Handler(void)
{

    UART_String(ch0msg,13);

}















