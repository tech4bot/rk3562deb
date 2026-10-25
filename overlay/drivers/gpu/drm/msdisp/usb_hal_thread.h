#ifndef __USB_HAL_THREAD_H__
#define __USB_HAL_THREAD_H__

//#define USB_HAL_BUF_TIMEOUT	2000
//#define USB_HAL_BUF_WAIT_TIME  20

struct usb_hal_dev;

int usb_hal_state_machine_entry(void* data);
void usb_hal_stop_thread(struct usb_hal_dev *usb_dev);

#endif