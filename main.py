import cv2
import requests
import numpy as np

def get_mask(frame, bodypix_url='http://localhost:9000'):
    _, data = cv2.imencode(".jpg", frame)
    r = requests.post(
        url=bodypix_url,
        data=data.tobytes(),
        headers={'Content-Type': 'application/octet-stream'})
    # convert raw bytes to a numpy array
    # raw data is uint8[width * height] with value 0 or 1
    mask = np.frombuffer(r.content, dtype=np.uint8)
    mask = mask.reshape((frame.shape[0], frame.shape[1]))
    return mask

def post_process_mask(mask):
    mask = cv2.blur(mask.astype(float), (4, 4))
    return mask

cap = cv2.VideoCapture(0)

height, width = 720, 1280
cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT,height)
cap.set(cv2.CAP_PROP_FPS, 60)

while True:
    success, frame = cap.read()
    mask = get_mask(frame)

    # read in a "virtual background" (should be in 16:9 ratio)
    replacement_bg_raw = cv2.imread("background.jpg")

    # resize to match the frame (width & height from before)
    width, height = 1280, 720
    replacement_bg = cv2.resize(replacement_bg_raw, (width, height))

    # combine the background and foreground, using the mask and its inverse
    inv_mask = 1 - mask
    for c in range(frame.shape[2]):
        frame[:,:,c] = frame[:,:,c] * mask + replacement_bg[:,:,c] * inv_mask

    cv2.imshow('frame', frame)
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break
