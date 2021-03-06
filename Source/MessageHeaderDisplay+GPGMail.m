//
//  MessageHeaderDisplay+GPGMail.m
//  GPGMail
//
//  Created by Lukas Pitschl on 31.07.11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import <MFError.h>
#import <MimePart.h>
#import <MimeBody.h>
#import <NSAttributedString-FontAdditions.h>
#import <MessageHeaderDisplay.h>
#import <MessageViewingState.h>
#import <NSAlert-MFErrorSupport.h>
#import "CCLog.h"
#import "NSObject+LPDynamicIvars.h"
#import "GPGSignatureView.h"
#import "GPGAttachmentController.h"
#import "GPGMailBundle.h"
#import "Message+GPGMail.h"
#import "MimePart+GPGMail.h"
#import "MimeBody+GPGMail.h"
#import "NSAttributedString+GPGMail.h"
#import "MessageHeaderDisplay+GPGMail.h"
#import "MessageContentController+GPGMail.h"
#import "EmailViewController.h"

@interface NSAttributedString (NSAttributedString_MoreExtensions)

/** 
 * @method allAttachments 
 * @abstract Fetchs all attachments from an NSAttributedString. 
 * @discussion This method searchs for NSAttachmentAttributeName attributes within the string instead of searching for NSAttachmentCharacter characters. 
 */
- (NSArray *)allAttachments;

@end

@implementation NSAttributedString (NSAttributedString_MoreExtensions)
- (NSArray *)allAttachments
{
    NSMutableArray *theAttachments = [NSMutableArray array];
    NSRange theStringRange = NSMakeRange(0, [self length]);
    if (theStringRange.length > 0)
    {
        unsigned long N = 0;
        do
        {
            NSRange theEffectiveRange;
            NSDictionary *theAttributes = [self attributesAtIndex:N longestEffectiveRange:&theEffectiveRange inRange:theStringRange];
            NSTextAttachment *theAttachment = theAttributes[NSAttachmentAttributeName];
            if (theAttachment != NULL)
                [theAttachments addObject:theAttachment];
            N = theEffectiveRange.location + theEffectiveRange.length;
        }
        while (N < theStringRange.length);
    }
    return(theAttachments);
}

@end

@implementation MessageHeaderDisplay_GPGMail

- (BOOL)MATextView:(id)textView clickedOnLink:(id)link atIndex:(unsigned long long)index {
    if(![link isEqualToString:@"gpgmail://show-signature"] && ![link isEqualToString:@"gpgmail://decrypt"] &&
       ![link isEqualToString:@"gpgmail://show-attachments"])
        return [self MATextView:textView clickedOnLink:link atIndex:index];
    if([link isEqualToString:@"gpgmail://decrypt"]) {
        [self _decryptMessage];
        return YES;
    }
    if([link isEqualToString:@"gpgmail://show-signature"]) {
        [self _showSignaturePanel];
    }
    if([link isEqualToString:@"gpgmail://show-attachments"]) {
        [self _showAttachmentsPanel];
    }
    return NO;
}

- (void)_showAttachmentsPanel {
    NSArray *pgpAttachments = ((Message *)[(MessageViewingState *)[((MessageHeaderDisplay *)self) viewingState] message]).PGPAttachments;
    
    GPGAttachmentController *attachmentController = [[GPGAttachmentController alloc] initWithAttachmentParts:pgpAttachments];
    attachmentController.keyList = [[GPGMailBundle sharedInstance] allGPGKeys];
    [attachmentController beginSheetModalForWindow:[NSApp mainWindow] completionHandler:^(NSInteger result) {
    }];
    // Set is an an ivar of MessageHeaderDisplay so it's released, once
    // the Message Header Display is closed.
    [self setIvar:@"AttachmentController" value:attachmentController];
}

- (void)_showSignaturePanel {
    NSArray *messageSigners = [self getIvar:@"messageSigners"];
    if(![messageSigners count])
        return;
    BOOL notInKeychain = NO;
    for(GPGSignature *signature in messageSigners) {
        if(!signature.primaryKey) {
            notInKeychain = YES;
            break;
        }
    }
    if(notInKeychain) {
        NSString *title = GMLocalizedString(@"MESSAGE_ERROR_ALERT_PGP_VERIFY_NOT_IN_KEYCHAIN_TITLE");
        NSString *message = GMLocalizedString(@"MESSAGE_ERROR_ALERT_PGP_VERIFY_NOT_IN_KEYCHAIN_MESSAGE");
        
        MFError *error = [MFError errorWithDomain:@"MFMessageErrorDomain" code:1035 localizedDescription:message title:title helpTag:nil userInfo:@{@"_MFShortDescription": title, @"NSLocalizedDescription": message}];
        // NSAlert has different category methods based on the version of OS X.
		NSAlert *alert = nil;
		if([[NSAlert class] respondsToSelector:@selector(alertForError:defaultButton:alternateButton:otherButton:)]) {
			alert = [NSAlert alertForError:error defaultButton:@"OK" alternateButton:nil otherButton:nil];
		}
		else if([[NSAlert class] respondsToSelector:@selector(alertForError:firstButton:secondButton:thirdButton:)]) {
			alert = [NSAlert alertForError:error firstButton:@"OK" secondButton:nil thirdButton:nil];
		}
		
		[alert beginSheetModalForWindow:[NSApp mainWindow] modalDelegate:self didEndSelector:nil contextInfo:nil];
        return;
    }
    GPGSignatureView *signatureView = [GPGSignatureView signatureView];
    signatureView.keyList = [[GPGMailBundle sharedInstance] allGPGKeys];
    signatureView.signatures = messageSigners; 
    [signatureView beginSheetModalForWindow:[NSApp mainWindow] completionHandler:^(NSInteger result) {
//        DebugLog(@"Signature panel was closed: %d", result);
    }];
}

- (void)_decryptMessage {
    [[[((MessageHeaderDisplay *)self) parentController] parentController] decryptPGPMessage];
}

- (id)MA_attributedStringForSecurityHeader {
    // This is also called if the message is neither signed nor encrypted.
    // In that case the empty string is returned.
    // Internally this method checks the message's messageFlags
    // to determine if the message is signed or encrypted and
    // based on that information creates the encrypted symbol
    // and calls copySingerLabels on the topLevelPart.
    MessageViewingState *viewingState = [((MessageHeaderDisplay *)self) viewingState];
    MimeBody *mimeBody = [viewingState mimeBody];
    Message *message = [viewingState message];
    
    // Check if message should be processed (-[Message shouldBePGPProcessed] - Snippet generation check)
    // otherwise out of here!
    if(![message shouldBePGPProcessed])
        return [self MA_attributedStringForSecurityHeader];
    
    // Check if the securityHeader is already set.
    // If so, out of here!
    if(viewingState.headerSecurityString)
        return viewingState.headerSecurityString;
    
    // Check the mime body, is more reliable.
    BOOL isPGPSigned = message.PGPSigned;
    BOOL isPGPEncrypted = message.PGPEncrypted && ![mimeBody ivarExists:@"PGPEarlyAlphaFuckedUpEncrypted"];
    BOOL hasPGPAttachments = message.numberOfPGPAttachments > 0 ? YES : NO;
    
    if(!isPGPSigned && !isPGPEncrypted && !hasPGPAttachments)
        return [self MA_attributedStringForSecurityHeader];
    
    NSMutableAttributedString *securityHeader = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@%@", [GPGMailBundle isMountainLion] ? @"      " : @"\t",
									NSLocalizedStringFromTableInBundle(@"SECURITY_HEADER", @"Encryption", [NSBundle mainBundle], @"")]];
    if(![GPGMailBundle isMountainLion]) {
		[securityHeader addAttributes:[NSAttributedString boldGrayHeaderAttributes] range:NSMakeRange(0, [securityHeader length])];
	}
	
    
    // Add the encrypted part to the security header.
    if(isPGPEncrypted) {
        NSImage *encryptedBadge = message.PGPDecrypted ? [NSImage imageNamed:@"NSLockUnlockedTemplate"] : [NSImage imageNamed:@"NSLockLockedTemplate"];
        NSString *linkID = message.PGPDecrypted ? nil : @"gpgmail://decrypt";
        NSAttributedString *encryptAttachmentString = [NSAttributedString attributedStringWithAttachment:[[NSTextAttachment alloc] init] 
                                                                                                   image:encryptedBadge
                                                                                                    link:linkID];
        [securityHeader appendAttributedString:[NSAttributedString attributedStringWithString:@"\t"]];
        [securityHeader appendAttributedString:encryptAttachmentString];
        
        NSString *encryptedString = message.PGPPartlyEncrypted ? GMLocalizedString(@"MESSAGE_IS_PGP_PARTLY_ENCRYPTED") :
                                                                            GMLocalizedString(@"MESSAGE_IS_PGP_ENCRYPTED");
        [securityHeader appendAttributedString:[NSAttributedString attributedStringWithString:[NSString stringWithFormat:@" %@", encryptedString]]];
    }
    if(isPGPSigned) {
        NSAttributedString *securityHeaderSignaturePart = [self securityHeaderSignaturePartForMessage:message];
        [self setIvar:@"messageSigners" value:message.PGPSignatures];

        // Only add, if message was encrypted.
        if(isPGPEncrypted)
            [securityHeader appendAttributedString:[NSAttributedString attributedStringWithString:@", "]];

        [securityHeader appendAttributedString:securityHeaderSignaturePart];
    }
    NSUInteger numberOfPGPAttachments = message.numberOfPGPAttachments;
    // And last but not least, add a new line.
    if(numberOfPGPAttachments) {
        NSAttributedString *securityHeaderAttachmentsPart = [self securityHeaderAttachmentsPartForMessage:message];
        
        if(message.PGPSigned || message.PGPEncrypted)
            [securityHeader appendAttributedString:[NSAttributedString attributedStringWithString:@", "]];
        [securityHeader appendAttributedString:securityHeaderAttachmentsPart];
    }
    [securityHeader appendAttributedString:[NSAttributedString attributedStringWithString:@"\n"]];
    viewingState.headerSecurityString = securityHeader;
    
    return securityHeader;
}

- (NSAttributedString *)securityHeaderAttachmentsPartForMessage:(Message *)message {
    BOOL hasEncryptedAttachments = NO;
    BOOL hasSignedAttachments = NO;
    BOOL singular = message.numberOfPGPAttachments > 1 ? NO : YES;
    
    NSMutableAttributedString *securityHeaderAttachmentsPart = [[NSMutableAttributedString alloc] init];
    [securityHeaderAttachmentsPart appendAttributedString:[NSAttributedString attributedStringWithAttachment:[[NSTextAttachment alloc] init] image:[NSImage imageNamed:@"attachment_header"] link:@"gpgmail://show-attachments"]];
    
    
    for(MimePart *attachment in message.PGPAttachments) {
        hasEncryptedAttachments |= attachment.PGPEncrypted;
        hasSignedAttachments |= attachment.PGPSigned;
    }
    
    NSString *attachmentPart = nil;
    
    if(hasEncryptedAttachments && hasSignedAttachments) {
        attachmentPart = (singular ? 
            GMLocalizedString(@"MESSAGE_SECURITY_HEADER_ATTACHMENT_SIGNED_ENCRYPTED_TITLE") :
            GMLocalizedString(@"MESSAGE_SECURITY_HEADER_ATTACHMENTS_SIGNED_ENCRYPTED_TITLE"));
    }
    else if(hasEncryptedAttachments) {
        attachmentPart = (singular ? 
            GMLocalizedString(@"MESSAGE_SECURITY_HEADER_ATTACHMENT_ENCRYPTED_TITLE") :
            GMLocalizedString(@"MESSAGE_SECURITY_HEADER_ATTACHMENTS_ENCRYPTED_TITLE"));
    }
    else if(hasSignedAttachments) {
        attachmentPart = (singular ? 
            GMLocalizedString(@"MESSAGE_SECURITY_HEADER_ATTACHMENT_SIGNED_TITLE") :
            GMLocalizedString(@"MESSAGE_SECURITY_HEADER_ATTACHMENTS_SIGNED_TITLE"));
    }
    
    [securityHeaderAttachmentsPart appendAttributedString:[NSAttributedString attributedStringWithString:[NSString stringWithFormat:@"%li %@", (long)message.numberOfPGPAttachments, attachmentPart]]];
    
    return securityHeaderAttachmentsPart;
}

- (NSAttributedString *)securityHeaderSignaturePartForMessage:(Message *)message {
    GPGErrorCode errorCode = GPGErrorNoError;
    BOOL errorFound = NO;
    NSImage *signedImage = nil;
    NSSet *signatures = [NSSet setWithArray:message.PGPSignatures];
    
    NSMutableAttributedString *securityHeaderSignaturePart = [[NSMutableAttributedString alloc] init];
    
    for(GPGSignature *signature in signatures) {
        if(signature.status != GPGErrorNoError) {
            errorCode = signature.status;
            break;
        }
    }
    errorFound = errorCode != GPGErrorNoError ? YES : NO;
    
	// Check if MacGPG2 was not found.
	// If that's the case, don't try to append signature labels.
	if(!errorFound) {
		GPGErrorCode __block newErrorCode = GPGErrorNoError;
		[[message PGPErrors] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
			if([obj isKindOfClass:[MFError class]]) {
				if(((NSDictionary *)[(MFError *)obj userInfo])[@"VerificationErrorCode"])
					newErrorCode = (GPGErrorCode)[((NSDictionary *)[(MFError *)obj userInfo])[@"VerificationErrorCode"] longValue];
				*stop = YES;
			}
		}];
		errorCode = newErrorCode;
	}
	
	NSString *titlePart = nil;
    
    switch (errorCode) {
        case GPGErrorNoPublicKey:
            titlePart = GMLocalizedString(@"MESSAGE_SECURITY_HEADER_SIGNATURE_NO_PUBLIC_KEY_TITLE");
            break;
            
        case GPGErrorCertificateRevoked:
            titlePart = GMLocalizedString(@"MESSAGE_SECURITY_HEADER_SIGNATURE_REVOKED_TITLE");
            break;
            
        case GPGErrorBadSignature:
            titlePart = GMLocalizedString(@"MESSAGE_SECURITY_HEADER_SIGNATURE_BAD_TITLE");
            break;
            
        default:
            titlePart = GMLocalizedString(@"MESSAGE_SECURITY_HEADER_SIGNATURE_TITLE");
            break;
    }
    
    if(!errorFound) {
        titlePart = GMLocalizedString(@"MESSAGE_SECURITY_HEADER_SIGNATURE_TITLE");
        signedImage = [NSImage imageNamed:@"SignatureOnTemplate"];
    }
    else {
        signedImage = [NSImage imageNamed:@"SignatureOffTemplate"];
    }
    
    
    if(message.PGPPartlySigned) {
// TODO: Implement different messages for partly signed messages.
        titlePart = GMLocalizedString(@"MESSAGE_IS_PGP_PARTLY_SIGNED");
    }
    
    NSSet *signerLabels = [NSSet setWithArray:[message PGPSignatureLabels]];
    NSAttributedString *signedAttachmentString = [NSAttributedString attributedStringWithAttachment:[[NSTextAttachment alloc] init] 
                                                                                              image:signedImage 
                                                                                               link:@"gpgmail://show-signature"];
    
    [securityHeaderSignaturePart appendAttributedString:signedAttachmentString];
    
    NSMutableString *signerLabelsString = [NSMutableString stringWithString:titlePart];
	// No MacGPG2? No signer labels!
	if(errorCode != GPGErrorNotFound && [[signerLabels allObjects] count] != 0)
		[signerLabelsString appendFormat:@" (%@)", [[signerLabels allObjects] componentsJoinedByString:@", "]];
    
	[securityHeaderSignaturePart appendAttributedString:[NSAttributedString attributedStringWithString:signerLabelsString]];
    return securityHeaderSignaturePart;
}

@end
